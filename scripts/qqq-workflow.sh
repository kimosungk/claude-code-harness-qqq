#!/usr/bin/env bash
# qqq-workflow — fzf + tmux orchestrator for the qqq plugin phase workflow.
#
# New sessions bootstrap directly into linked worktrees under
# .qqq-worktrees/<slug>/.../claude-works/YYYY-MM-DD_<slug>/.
# Legacy pre-worktree sessions may still exist under
# ${QQQ_WORKS_DIR:-$PWD/claude-works}/YYYY-MM-DD_<slug>/, but qqq only keeps
# them visible for discard; they cannot be resumed.
#
# Each phase agent runs in its own tmux window; windows do NOT auto-close on
# agent exit (an interactive shell takes over so the user can inspect).
#
# Install:
#   alias qqq="$HOME/.claude/plugins/local/hskim-plugins/plugins/qqq/scripts/qqq-workflow.sh"
#
# Usage:
#   qqq                          # launch interactive scope menu (sessions + repository actions)
#   qqq --help                   # show usage
#   qqq --session <dir>          # skip session picker, start in <dir>
#   qqq --merge-resume-push      # retry `push origin <dev>` for a prior merge and cleanup
#   picker keys                  # Enter selects, Delete discards active sessions
#
# Environment:
#   QQQ_WORKS_DIR  claude-works base (default: $PWD/claude-works)
#   QQQ_DEV_BRANCH origin dev branch name (default: dev)
#   QQQ_NO_FETCH=1 skip `git fetch origin <dev>` in session bootstrap/merge/MR preflight

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf '[qqq] requires bash 4+ (found %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

export LC_ALL="${LC_ALL:-C.UTF-8}"

# TMUX_SESSION_NAME is set in main() as "qqq|<repo-slug>" for per-repo isolation.
# The separator is "|" (not ":"): tmux parses -t target as "session:window.pane",
# so a colon inside the session name breaks every target lookup.
export TMUX_SESSION_NAME=""
readonly DEFAULT_ITERATIONS=1
readonly QQQ_LOG_SCHEMA_VERSION="1"

QQQ_WORKS_DIR="${QQQ_WORKS_DIR:-$PWD/claude-works}"
QQQ_COMPLETED_DIR="${QQQ_COMPLETED_DIR:-$(dirname "$QQQ_WORKS_DIR")/claude-works-completed}"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[qqq] required command not found: %s\n' "$1" >&2
    exit 1
  }
}

check_deps() {
  need claude
  need fzf
  need tmux
  need flock
  need git
  if ! command -v codex >/dev/null 2>&1; then
    printf '[qqq] warning: `codex` not found on PATH — reviewer flows will use Claude fallback instead of Codex-first review.\n' >&2
  fi
  if ! command -v glab >/dev/null 2>&1; then
    printf '[qqq] warning: `glab` not found on PATH — GitLab MR actions will be unavailable.\n' >&2
  fi
}

qqq_test_queue_pop() {
  local queue_file="${1:-}"
  [[ -n "$queue_file" && -f "$queue_file" ]] || return 1
  local line
  line=$(head -n 1 "$queue_file" 2>/dev/null) || return 1
  tail -n +2 "$queue_file" >"${queue_file}.tmp.$$" 2>/dev/null || : >"${queue_file}.tmp.$$"
  mv "${queue_file}.tmp.$$" "$queue_file"
  printf '%s' "$line"
}

qqq_fzf() {
  if [[ -n "${QQQ_TEST_FZF_QUEUE_FILE:-}" ]]; then
    if [[ ! -t 0 ]]; then
      if [[ -n "${QQQ_TEST_FZF_CAPTURE_FILE:-}" ]]; then
        cat >"$QQQ_TEST_FZF_CAPTURE_FILE"
      else
        cat >/dev/null
      fi
    fi
    qqq_test_queue_pop "$QQQ_TEST_FZF_QUEUE_FILE"
    return $?
  fi
  command fzf "$@"
}

qqq_read_prompt() {
  local prompt="$1" dest_var="$2"
  local value=""
  if [[ -n "${QQQ_TEST_PROMPT_QUEUE_FILE:-}" ]]; then
    value=$(qqq_test_queue_pop "$QQQ_TEST_PROMPT_QUEUE_FILE") || return 1
  else
    read -rp "$prompt" value </dev/tty || return 1
  fi
  printf -v "$dest_var" '%s' "$value"
}

# ---------------------------------------------------------------------------
# Environment guards
# ---------------------------------------------------------------------------

check_nested_tmux() {
  [[ -n "${TMUX:-}" ]] || return 0
  local current
  current=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
  if [[ "$current" != "$TMUX_SESSION_NAME" ]]; then
    printf '[qqq] refusing to run inside tmux session "%s". Run qqq outside tmux, or reattach to the existing "%s" session first.\n' \
      "$current" "$TMUX_SESSION_NAME" >&2
    exit 1
  fi
}

acquire_lock() {
  local sess="$1"
  local lock_file="$sess/.qqq.lock"
  # fd 9 stays open for the lifetime of this process; flock releases on exit.
  exec 9<>"$lock_file"
  if ! flock -n 9; then
    local owner
    owner=$(cat "$lock_file" 2>/dev/null)
    owner=${owner:-unknown}
    printf '[qqq] session "%s" is locked by PID %s — another qqq running?\n' \
      "$(basename "$sess")" "$owner" >&2
    exec 9<&- 2>/dev/null || true
    return 1
  fi
  # Overwrite with our PID only after acquiring.
  printf '%s\n' "$$" >"$lock_file"
}

release_session_lock() {
  flock -u 9 2>/dev/null || true
  exec 9<&- 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Worktree helpers (Stage 1 foundation; consumers land in later stages)
# ---------------------------------------------------------------------------

qqq_is_in_git_repo() {
  local path="${1:-$PWD}"
  git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1
}

qqq_worktree_bucket_dir() {
  local repo_root="$1"
  printf '%s/.qqq-worktrees' "$repo_root"
}

qqq_worktree_path_for() {
  local repo_root="$1" slug="$2"
  printf '%s/%s' "$(qqq_worktree_bucket_dir "$repo_root")" "$slug"
}

qqq_worktree_branch_for() {
  printf 'qqq/%s' "$1"
}

qqq_origin_dev_branch() {
  printf '%s' "${QQQ_DEV_BRANCH:-dev}"
}

qqq_launch_cwd() {
  printf '%s' "${QQQ_LAUNCH_PWD:-$PWD}"
}

qqq_path_join() {
  local base="$1" rel="${2:-}"
  if [[ -z "$base" ]]; then
    printf '%s' "$rel"
  elif [[ -z "$rel" || "$rel" == "." ]]; then
    printf '%s' "$base"
  else
    printf '%s/%s' "$base" "$rel"
  fi
}

qqq_launch_rel_from_repo() {
  local repo_root="$1"
  local launch_cwd
  launch_cwd=$(cd "$(qqq_launch_cwd)" 2>/dev/null && pwd) || launch_cwd=$(qqq_launch_cwd)
  if [[ "$launch_cwd" == "$repo_root" ]]; then
    return 0
  fi
  if [[ "$launch_cwd" == "$repo_root/"* ]]; then
    printf '%s' "${launch_cwd#"$repo_root"/}"
    return 0
  fi
  return 1
}

qqq_checkout_exec_cwd() {
  local checkout_root="$1" leader_repo="$2"
  local rel
  if rel=$(qqq_launch_rel_from_repo "$leader_repo" 2>/dev/null); then
    qqq_path_join "$checkout_root" "$rel"
  elif [[ "$checkout_root" == "$leader_repo" ]]; then
    qqq_launch_cwd
  else
    printf '%s' "$checkout_root"
  fi
}

qqq_session_base_for_checkout() {
  local checkout_root="$1" leader_repo="$2"
  printf '%s/claude-works' "$(qqq_checkout_exec_cwd "$checkout_root" "$leader_repo")"
}

qqq_completed_base_for_checkout() {
  local checkout_root="$1" leader_repo="$2"
  printf '%s/claude-works-completed' "$(qqq_checkout_exec_cwd "$checkout_root" "$leader_repo")"
}

qqq_agent_launch_cwd_for_session() {
  local session_dir="$1"
  local leader_repo wt_root
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$(qqq_launch_cwd)" 2>/dev/null) \
    || {
      qqq_launch_cwd
      return 0
    }
  wt_root=$(qqq_session_dir_worktree "$session_dir")
  if [[ -n "$wt_root" ]]; then
    qqq_checkout_exec_cwd "$wt_root" "$leader_repo"
  else
    qqq_launch_cwd
  fi
}

qqq_ensure_worktree_bucket_ignored() {
  local repo_root="$1"
  local bucket_path
  bucket_path=$(qqq_worktree_bucket_dir "$repo_root")
  if qqq_check_gitignore "$repo_root" "$bucket_path" 2>/dev/null; then
    return 0
  fi

  local exclude_file
  exclude_file=$(git -C "$repo_root" rev-parse --git-path info/exclude 2>/dev/null) || return 1
  [[ "$exclude_file" = /* ]] || exclude_file="$repo_root/$exclude_file"
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  if ! grep -qxF '/.qqq-worktrees/' "$exclude_file" 2>/dev/null; then
    printf '\n/.qqq-worktrees/\n' >>"$exclude_file"
  fi
  mkdir -p "$bucket_path"
  qqq_check_gitignore "$repo_root" "$bucket_path" 2>/dev/null
}

qqq_origin_default_branch() {
  local repo_root="$1"
  local ref
  ref=$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
  printf '%s' "${ref#origin/}"
}

qqq_branch_exists() {
  # scope: local | remote | any (default any)
  local repo_root="$1" branch="$2" scope="${3:-any}"
  case "$scope" in
    local)
      git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"
      ;;
    remote)
      git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$branch"
      ;;
    any)
      git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" \
        || git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$branch"
      ;;
    *)
      return 2
      ;;
  esac
}

qqq_check_gitignore() {
  # 0 = ignored, 1 = not ignored, other = error (no repo, etc.).
  local repo_root="$1" path="$2"
  local rel_path="$path"
  if [[ "$path" == "$repo_root/"* ]]; then
    rel_path="${path#"$repo_root"/}"
  fi
  git -C "$repo_root" check-ignore -q -- "$rel_path"
}

qqq_list_worktrees() {
  # Output: <path>\t<branch>\t<physical=yes|no>   (branch may be empty for detached HEAD)
  local repo_root="$1"
  local path="" branch="" physical
  local line
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      path="${line#worktree }"
      branch=""
    elif [[ "$line" == branch\ * ]]; then
      branch="${line#branch refs/heads/}"
    elif [[ -z "$line" ]]; then
      if [[ -n "$path" ]]; then
        physical=yes
        [[ -d "$path" ]] || physical=no
        printf '%s\t%s\t%s\n' "$path" "$branch" "$physical"
      fi
      path=""; branch=""
    fi
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
  if [[ -n "$path" ]]; then
    physical=yes
    [[ -d "$path" ]] || physical=no
    printf '%s\t%s\t%s\n' "$path" "$branch" "$physical"
  fi
}

qqq_worktree_rebase_in_progress() {
  local worktree="$1"
  local git_dir
  git_dir=$(git -C "$worktree" rev-parse --git-dir 2>/dev/null) || return 1
  [[ "$git_dir" = /* ]] || git_dir="$worktree/$git_dir"
  [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]
}

qqq_session_dir_worktree() {
  # Emit the linked-worktree root if session_dir lives inside one; empty on primary / outside any repo.
  local session_dir="$1"
  [[ -d "$session_dir" ]] || return 0
  local top git_common git_actual
  top=$(git -C "$session_dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  git_common=$(git -C "$session_dir" rev-parse --git-common-dir 2>/dev/null) || return 0
  git_actual=$(git -C "$session_dir" rev-parse --git-dir 2>/dev/null) || return 0
  # git returns a mix of absolute / session_dir-relative paths. Resolve to canonical.
  [[ "$git_common" = /* ]] || git_common=$(cd "$session_dir" && cd "$git_common" 2>/dev/null && pwd) || git_common="$session_dir/$git_common"
  [[ "$git_actual" = /* ]] || git_actual=$(cd "$session_dir" && cd "$git_actual" 2>/dev/null && pwd) || git_actual="$session_dir/$git_actual"
  # Primary worktree: git-dir == git-common-dir. Linked worktree differs (.git/worktrees/<name>).
  if [[ "$git_common" != "$git_actual" ]]; then
    printf '%s' "$top"
  fi
}

qqq_session_is_legacy_blocked() {
  local session_dir="$1"
  [[ -d "$session_dir" ]] || return 1

  local base wt_root works_abs session_abs
  base=$(basename "$session_dir")
  [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_.+ ]] || return 1

  wt_root=$(qqq_session_dir_worktree "$session_dir")
  [[ -z "$wt_root" ]] || return 1

  works_abs=$(cd "$QQQ_WORKS_DIR" 2>/dev/null && pwd) || return 1
  session_abs=$(cd "$session_dir" 2>/dev/null && pwd) || return 1
  [[ "$session_abs" == "$works_abs/"* ]]
}

qqq_print_legacy_session_blocked_message() {
  printf '[qqq] this session predates the worktree-first format and cannot be resumed. Create a new session instead.\n' >&2
}

qqq_assert_session_resumable() {
  local session_dir="$1"
  if qqq_session_is_legacy_blocked "$session_dir"; then
    qqq_print_legacy_session_blocked_message
    return 1
  fi
  return 0
}

# Short-lived repo-level lock used by worktree write ops (create/merge/cleanup/post-commit).
# Uses fd 8, distinct from acquire_lock's fd 9, so both can be held concurrently.
qqq_acquire_repo_lock() {
  local repo_root="$1"
  local git_common
  git_common=$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [[ "$git_common" = /* ]] || git_common="$repo_root/$git_common"
  local lock_file="$git_common/qqq-repo.lock"
  exec 8<>"$lock_file"
  if ! flock -w 10 8; then
    printf '[qqq] repo lock busy (%s) — another qqq write op in progress.\n' "$lock_file" >&2
    return 1
  fi
  printf '%s\n' "$$" >"$lock_file" 2>/dev/null || true
}

qqq_release_repo_lock() {
  flock -u 8 2>/dev/null || true
  exec 8<&- 2>/dev/null || true
}

qqq_leader_repo_from() {
  # Emit the primary-worktree root of whatever git repo <start> is part of.
  local start="${1:-$PWD}"
  [[ -d "$start" ]] || start="$PWD"
  local common abs
  common=$(git -C "$start" rev-parse --git-common-dir 2>/dev/null) || return 1
  if [[ "$common" = /* ]]; then
    abs="$common"
  else
    abs=$(cd "$start" && cd "$common" 2>/dev/null && pwd) || abs="$start/$common"
  fi
  printf '%s' "$(dirname "$abs")"
}

qqq_repo_slug_from() {
  # Short identifier used in the tmux session name ("qqq|<repo-slug>").
  # Prefers the leader worktree basename; falls back to $PWD basename outside git.
  local start="${1:-$PWD}"
  local leader
  if leader=$(qqq_leader_repo_from "$start" 2>/dev/null); then
    basename "$leader"
  else
    basename "$start"
  fi
}

qqq_slug_from_session_dir() {
  local base
  base=$(basename "$1")
  if [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$base"
  fi
}

# Window-name slug: full session-dir basename (date included).
# Used only for tmux window naming; branch / worktree paths keep qqq_slug_from_session_dir.
qqq_window_slug_from_session_dir() {
  basename "$1"
}

qqq_is_managed_agent_role() {
  case "$1" in
    req-clarifier|ui-outliner|nltp-interviewer|tech-interviewer|code-planner|code-implementer|rebase-resolver)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

qqq_managed_agent_roles() {
  printf '%s\n' \
    req-clarifier \
    ui-outliner \
    nltp-interviewer \
    tech-interviewer \
    code-planner \
    code-implementer \
    rebase-resolver
}

qqq_iso_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'
}

qqq_json_escape() {
  local raw="${1-}"
  raw=${raw//\\/\\\\}
  raw=${raw//\"/\\\"}
  raw=${raw//$'\n'/\\n}
  raw=${raw//$'\r'/\\r}
  raw=${raw//$'\t'/\\t}
  printf '%s' "$raw"
}

qqq_json_string() {
  printf '"%s"' "$(qqq_json_escape "${1-}")"
}

qqq_json_object_from_pairs() {
  local json="{"
  local first=1
  while (( $# > 1 )); do
    local key="$1"
    local value="$2"
    shift 2
    if (( ! first )); then
      json+=","
    fi
    first=0
    json+="$(qqq_json_string "$key"):$(qqq_json_string "$value")"
  done
  json+="}"
  printf '%s' "$json"
}

qqq_json_unescape() {
  local raw="${1-}" out="" ch next
  local i=0 len=${#raw}
  while (( i < len )); do
    ch="${raw:i:1}"
    if [[ "$ch" == '\' && $(( i + 1 )) -lt len ]]; then
      i=$(( i + 1 ))
      next="${raw:i:1}"
      case "$next" in
        '"') out+='"' ;;
        '\') out+='\' ;;
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        *) out+="\\$next" ;;
      esac
    else
      out+="$ch"
    fi
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

qqq_tsv_field() {
  local line="${1-}" field_no="${2:?field number required}"
  printf '%s\n' "$line" | awk -F'\t' -v n="$field_no" '{ if (n <= NF) print $n }'
}

qqq_json_read_string_key() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  local escaped
  escaped=$(
    awk -v key="$key" '
      BEGIN {
        prefix = "\"" key "\""
        found = 0
      }
      $0 ~ "^[[:space:]]*" prefix "[[:space:]]*:" {
        line = $0
        sub("^[[:space:]]*" prefix "[[:space:]]*:[[:space:]]*\"", "", line)
        out = ""
        esc = 0
        for (i = 1; i <= length(line); i++) {
          ch = substr(line, i, 1)
          if (esc) {
            out = out "\\" ch
            esc = 0
            continue
          }
          if (ch == "\\") {
            esc = 1
            continue
          }
          if (ch == "\"") {
            found = 1
            print out
            exit 0
          }
          out = out ch
        }
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$file"
  ) || return 1
  qqq_json_unescape "$escaped"
}

qqq_write_json_file() {
  local path="$1"
  shift
  local tmp_path="${path}.tmp.$$"
  local total_pairs=$(( $# / 2 ))
  local pair_index=0
  mkdir -p "$(dirname "$path")" || return 1
  {
    printf '{\n'
    while (( $# > 1 )); do
      local key="$1"
      local value="$2"
      local comma=","
      shift 2
      pair_index=$(( pair_index + 1 ))
      if (( pair_index == total_pairs )); then
        comma=""
      fi
      printf '  %s: %s%s\n' "$(qqq_json_string "$key")" "$(qqq_json_string "$value")" "$comma"
    done
    printf '}\n'
  } >"$tmp_path" || {
    rm -f "$tmp_path" 2>/dev/null || true
    return 1
  }
  mv "$tmp_path" "$path"
}

qqq_merge_state_path() {
  printf '%s/.qqq/merge-state.json' "$1"
}

qqq_merge_state_write() {
  local session_dir="$1" status="$2" session_basename="$3" branch="$4" dev_branch="$5"
  local leader_repo="$6" worktree_path="$7" archived_session_dir="$8" premerge_tag="$9"
  local expected_dev_head="${10}" merge_commit_head="${11}" leader_archived_session_dir="${12}"
  local state_path
  state_path=$(qqq_merge_state_path "$session_dir")
  qqq_write_json_file "$state_path" \
    schema_version "1" \
    session_basename "$session_basename" \
    branch "$branch" \
    dev_branch "$dev_branch" \
    leader_repo "$leader_repo" \
    worktree_path "$worktree_path" \
    archived_session_dir "$archived_session_dir" \
    premerge_tag "$premerge_tag" \
    expected_dev_head "$expected_dev_head" \
    merge_commit_head "$merge_commit_head" \
    leader_archived_session_dir "$leader_archived_session_dir" \
    status "$status"
}

qqq_merge_state_get() {
  local session_dir="$1" key="$2"
  qqq_json_read_string_key "$(qqq_merge_state_path "$session_dir")" "$key"
}

qqq_merge_state_status() {
  qqq_merge_state_get "$1" status
}

qqq_session_merge_display_status() {
  local session_dir="$1"
  local merge_status="" wt_root=""
  wt_root=$(qqq_session_dir_worktree "$session_dir")
  merge_status=$(qqq_merge_state_status "$session_dir" 2>/dev/null || printf '')
  if [[ -n "$merge_status" ]]; then
    printf '%s' "$merge_status"
    return 0
  fi
  if [[ "$session_dir" == */claude-works-completed/* ]]; then
    printf 'completed'
  fi
}

qqq_session_list_suffix() {
  local merge_status
  merge_status=$(qqq_session_merge_display_status "$1")
  case "$merge_status" in
    push_pending) printf ' [push-pending]' ;;
    merged_local) printf ' [merged-local]' ;;
    rebased)      printf ' [rebased]' ;;
    archived)     printf ' [archived]' ;;
    completed)    printf ' [completed]' ;;
    *)            printf '' ;;
  esac
}

qqq_session_dedupe_key() {
  local session_dir="$1"
  local name merge_status suffix=""
  name=$(basename "$session_dir")
  merge_status=$(qqq_session_merge_display_status "$session_dir")
  if qqq_session_is_legacy_blocked "$session_dir"; then
    suffix="|legacy-blocked"
  fi
  if [[ -n "$merge_status" ]]; then
    printf '%s|%s%s' "$name" "$merge_status" "$suffix"
  else
    printf '%s%s' "$name" "$suffix"
  fi
}

qqq_merge_status_requires_recovery_warning() {
  case "${1:-}" in
    rebased|archived|merged_local|push_pending) return 0 ;;
    *) return 1 ;;
  esac
}

qqq_pid_is_alive() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

qqq_session_lock_info() {
  # Output: <present=yes|no>\t<pid>\t<alive=yes|no|unknown>
  local session_dir="$1"
  local lock_file="$session_dir/.qqq.lock"
  local pid="" alive="unknown"
  if [[ ! -e "$lock_file" ]]; then
    printf 'no\t\tunknown\n'
    return 0
  fi
  pid=$(head -n 1 "$lock_file" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$pid" ]]; then
    if qqq_pid_is_alive "$pid"; then
      alive="yes"
    else
      alive="no"
    fi
  fi
  printf 'yes\t%s\t%s\n' "$pid" "$alive"
}

qqq_session_discard_plan() {
  # Output:
  # <plan_kind>\t<force_required>\t<picker_scope>\t<merge_status>\t<leader_repo>\t<branch>\t
  # <wt_state>\t<wt_path>\t<local_branch=yes|no>\t<remote_branch=yes|no>\t
  # <lock_present=yes|no>\t<lock_pid>\t<lock_alive=yes|no|unknown>\t<impact_summary>
  local session_dir="$1"
  local picker_scope="${2:-}"
  [[ -n "$picker_scope" ]] || picker_scope=$(qqq_picker_session_scope "$session_dir" 2>/dev/null || printf 'active')

  local merge_status="" leader_repo="" status_line="" wt_path="" wt_state="no-repo"
  local slug="" branch="" local_branch="no" remote_branch="no"
  local lock_info="" lock_present="no" lock_pid="" lock_alive="unknown"
  local plan_kind="session-dir-only" force_required="no" impact_summary="session dir only"
  local legacy_blocked="no"

  merge_status=$(qqq_session_merge_display_status "$session_dir" 2>/dev/null || printf '')
  if qqq_session_is_legacy_blocked "$session_dir"; then
    legacy_blocked="yes"
  fi
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || leader_repo=""

  if [[ -n "$leader_repo" ]]; then
    status_line=$(qqq_session_worktree_status "$session_dir" "$leader_repo")
    wt_path="${status_line%$'\t'*}"
    wt_state="${status_line##*$'\t'}"
    wt_state="${wt_state%$'\n'}"
    slug=$(qqq_slug_from_session_dir "$session_dir")
    branch=$(qqq_worktree_branch_for "$slug")
    qqq_branch_exists "$leader_repo" "$branch" local 2>/dev/null && local_branch="yes"
    qqq_branch_exists "$leader_repo" "$branch" remote 2>/dev/null && remote_branch="yes"
  fi

  lock_info=$(qqq_session_lock_info "$session_dir")
  lock_present="${lock_info%%$'\t'*}"
  lock_info="${lock_info#*$'\t'}"
  lock_pid="${lock_info%%$'\t'*}"
  lock_alive="${lock_info##*$'\t'}"
  lock_alive="${lock_alive%$'\n'}"

  if [[ "$picker_scope" == "completed" ]]; then
    plan_kind="blocked"
    impact_summary="archive delete unsupported from picker"
  elif [[ "$legacy_blocked" == "yes" ]]; then
    plan_kind="session-dir-only"
    impact_summary="legacy session dir only"
  elif [[ "$wt_state" == "live" || "$wt_state" == "ghost" || "$wt_state" == "branch-only" || "$local_branch" == "yes" || "$remote_branch" == "yes" ]]; then
    plan_kind="full-cleanup"
    impact_summary="session dir + linked worktree + local branch"
  fi

  if [[ "$lock_present" == "yes" ]] || qqq_merge_status_requires_recovery_warning "$merge_status"; then
    force_required="yes"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$plan_kind" "$force_required" "$picker_scope" "$merge_status" "$leader_repo" "$branch" \
    "$wt_state" "$wt_path" "$local_branch" "$remote_branch" "$lock_present" "$lock_pid" \
    "$lock_alive" "$impact_summary"
}

qqq_execute_session_discard() {
  local session_dir="$1"
  local picker_scope="$2"
  local delete_remote="${3:-no}"
  local plan plan_kind force_required merge_status leader_repo branch wt_state wt_path
  local local_branch remote_branch lock_present lock_pid lock_alive impact_summary

  plan=$(qqq_session_discard_plan "$session_dir" "$picker_scope")
  plan_kind=$(qqq_tsv_field "$plan" 1)
  force_required=$(qqq_tsv_field "$plan" 2)
  merge_status=$(qqq_tsv_field "$plan" 4)
  leader_repo=$(qqq_tsv_field "$plan" 5)
  branch=$(qqq_tsv_field "$plan" 6)
  wt_state=$(qqq_tsv_field "$plan" 7)
  wt_path=$(qqq_tsv_field "$plan" 8)
  local_branch=$(qqq_tsv_field "$plan" 9)
  remote_branch=$(qqq_tsv_field "$plan" 10)
  lock_present=$(qqq_tsv_field "$plan" 11)
  lock_pid=$(qqq_tsv_field "$plan" 12)
  lock_alive=$(qqq_tsv_field "$plan" 13)
  impact_summary=$(qqq_tsv_field "$plan" 14)

  if [[ "$plan_kind" == "blocked" ]]; then
    printf '[qqq] archive delete unsupported from picker.\n' >&2
    return 1
  fi

  qqq_log_workflow_event "picker_discard" "started" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "picker_scope" "$picker_scope" \
    "plan_kind" "$plan_kind" \
    "merge_status" "$merge_status" \
    "worktree_state" "$wt_state"

  local repo_lock_held=no rc=0 pruned=no
  if [[ "$plan_kind" == "full-cleanup" && -n "$leader_repo" ]]; then
    if ! qqq_acquire_repo_lock "$leader_repo"; then
      qqq_log_workflow_event "picker_discard" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "repo lock busy"
      return 1
    fi
    repo_lock_held=yes
  fi

  if [[ -e "$session_dir/.qqq.lock" ]]; then
    rm -f "$session_dir/.qqq.lock" 2>/dev/null || true
  fi
  if [[ -e "$session_dir" ]]; then
    if rm -rf "$session_dir" 2>/dev/null; then
      printf '[qqq] removed session dir %s\n' "$session_dir"
    else
      printf '[qqq] failed to remove session dir %s\n' "$session_dir" >&2
      rc=1
    fi
  fi

  if [[ "$plan_kind" == "full-cleanup" && -n "$leader_repo" ]]; then
    case "$wt_state" in
      live)
        if [[ -n "$wt_path" ]]; then
          if git -C "$leader_repo" worktree remove --force "$wt_path" 2>/dev/null; then
            printf '[qqq] removed worktree %s\n' "$wt_path"
          else
            if rm -rf "$wt_path" 2>/dev/null; then
              printf '[qqq] force-removed worktree %s\n' "$wt_path"
            else
              printf '[qqq] failed to remove worktree %s\n' "$wt_path" >&2
              rc=1
            fi
          fi
          pruned=yes
        fi
        ;;
      ghost)
        pruned=yes
        ;;
      branch-only)
        pruned=yes
        ;;
    esac

    if [[ "$pruned" == "yes" ]]; then
      git -C "$leader_repo" worktree prune 2>/dev/null || true
    fi

    if [[ "$local_branch" == "yes" ]]; then
      if git -C "$leader_repo" branch -D "$branch" 2>/dev/null; then
        printf '[qqq] deleted local branch %s\n' "$branch"
      else
        printf '[qqq] could not delete local branch %s (still checked out somewhere?)\n' "$branch" >&2
        rc=1
      fi
    fi

    if [[ "$delete_remote" == "yes" && "$remote_branch" == "yes" ]]; then
      if git -C "$leader_repo" push origin --delete "$branch" 2>/dev/null; then
        printf '[qqq] deleted remote branch %s\n' "$branch"
      else
        local url
        url=$(git -C "$leader_repo" config --get remote.origin.url 2>/dev/null)
        printf '[qqq] could not delete remote branch (protected?). Delete via GitLab UI: %s/-/branches\n' "$url" >&2
        rc=1
      fi
    fi
  fi

  if [[ "$repo_lock_held" == "yes" ]]; then
    qqq_release_repo_lock
  fi

  if (( rc != 0 )) && [[ -d "$session_dir" ]]; then
    qqq_log_workflow_event "picker_discard" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "cleanup incomplete" \
      "picker_scope" "$picker_scope" \
      "plan_kind" "$plan_kind" \
      "remote_deleted" "$delete_remote"
  fi
  return "$rc"
}

qqq_picker_discard_session() {
  local row="$1"
  local label="" session_dir="" picker_scope="" merge_status="" wt_state="" wt_path=""
  local lock_present="" lock_pid=""
  label=$(qqq_tsv_field "$row" 1)
  session_dir=$(qqq_tsv_field "$row" 2)
  picker_scope=$(qqq_tsv_field "$row" 3)
  merge_status=$(qqq_tsv_field "$row" 4)
  wt_state=$(qqq_tsv_field "$row" 5)
  wt_path=$(qqq_tsv_field "$row" 6)
  lock_present=$(qqq_tsv_field "$row" 7)
  lock_pid=$(qqq_tsv_field "$row" 8)

  local plan plan_kind force_required leader_repo branch local_branch remote_branch lock_alive impact_summary
  plan=$(qqq_session_discard_plan "$session_dir" "$picker_scope")
  plan_kind=$(qqq_tsv_field "$plan" 1)
  force_required=$(qqq_tsv_field "$plan" 2)
  merge_status=$(qqq_tsv_field "$plan" 4)
  leader_repo=$(qqq_tsv_field "$plan" 5)
  branch=$(qqq_tsv_field "$plan" 6)
  wt_state=$(qqq_tsv_field "$plan" 7)
  wt_path=$(qqq_tsv_field "$plan" 8)
  local_branch=$(qqq_tsv_field "$plan" 9)
  remote_branch=$(qqq_tsv_field "$plan" 10)
  lock_present=$(qqq_tsv_field "$plan" 11)
  lock_pid=$(qqq_tsv_field "$plan" 12)
  lock_alive=$(qqq_tsv_field "$plan" 13)
  impact_summary=$(qqq_tsv_field "$plan" 14)

  if [[ "$plan_kind" == "blocked" ]]; then
    printf '[qqq] archive delete unsupported from picker.\n' >&2
    return 0
  fi

  printf '[qqq] discard %s\n' "$label" >&2
  printf '[qqq] impact: %s\n' "$impact_summary" >&2
  if [[ "$remote_branch" == "yes" ]]; then
    printf '[qqq] remote branch present: origin/%s (separate confirm required)\n' "$branch" >&2
  fi
  if [[ "$lock_present" == "yes" ]]; then
    if [[ -n "$lock_pid" ]]; then
      printf '[qqq] warning: session lock present (pid %s, alive=%s).\n' "$lock_pid" "$lock_alive" >&2
    else
      printf '[qqq] warning: session lock present.\n' >&2
    fi
  fi
  if qqq_merge_status_requires_recovery_warning "$merge_status"; then
    printf '[qqq] warning: session is in merge recovery state [%s].\n' "${merge_status//_/-}" >&2
  fi

  local reply delete_remote=no
  if [[ "$force_required" == "yes" ]]; then
    qqq_read_prompt "[qqq] type FORCE to discard this session: " reply || return 1
    if [[ "$reply" != "FORCE" ]]; then
      printf '[qqq] discard aborted.\n' >&2
      return 0
    fi
  else
    qqq_read_prompt "[qqq] discard this session? [y/N]: " reply || return 1
    if [[ "$reply" != [Yy]* ]]; then
      printf '[qqq] discard aborted.\n' >&2
      return 0
    fi
  fi

  if [[ "$remote_branch" == "yes" ]]; then
    qqq_read_prompt "[qqq] delete remote branch origin/$branch too? [y/N]: " reply || return 1
    [[ "$reply" == [Yy]* ]] && delete_remote=yes
  fi

  qqq_execute_session_discard "$session_dir" "$picker_scope" "$delete_remote"
}

qqq_picker_should_include_session() {
  local session_dir="$1"
  if [[ "$session_dir" == */claude-works-completed/* ]]; then
    local archived_session_dir
    archived_session_dir=$(qqq_merge_state_get "$session_dir" archived_session_dir 2>/dev/null || printf '')
    if [[ -n "$archived_session_dir" && "$archived_session_dir" != "$session_dir" && -d "$archived_session_dir" ]]; then
      return 1
    fi
  fi
  return 0
}

qqq_picker_session_scope() {
  local session_dir="$1"
  qqq_picker_should_include_session "$session_dir" || return 1
  local merge_status
  merge_status=$(qqq_session_merge_display_status "$session_dir")
  if [[ "$merge_status" == "completed" ]]; then
    printf 'completed'
  else
    printf 'active'
  fi
}

qqq_log_workflow_event() {
  local event="$1" result="$2" agent_type="$3" session_dir="$4"
  shift 4
  [[ -n "$session_dir" ]] || return 0
  mkdir -p "$session_dir/.qqq" 2>/dev/null || return 0
  local details_json
  details_json=$(qqq_json_object_from_pairs "$@")
  printf '{"schema_version":"1","ts":%s,"source":"workflow","event":%s,"result":%s,"agent_type":%s,"session_dir":%s,"cwd":%s,"details":%s}\n' \
    "$(qqq_json_string "$(qqq_iso_timestamp)")" \
    "$(qqq_json_string "$event")" \
    "$(qqq_json_string "$result")" \
    "$(qqq_json_string "$agent_type")" \
    "$(qqq_json_string "$session_dir")" \
    "$(qqq_json_string "$PWD")" \
    "$details_json" >>"$session_dir/.qqq/log.jsonl"
}

qqq_session_worktree_status() {
  # Output: <worktree_path>\t<state>
  # state ∈ {live, ghost, branch-only, none, no-repo}
  local session_dir="$1" leader_repo="$2"
  if [[ -z "$leader_repo" ]]; then
    printf '\tno-repo\n'
    return 0
  fi
  local slug branch path entry_branch phys
  slug=$(qqq_slug_from_session_dir "$session_dir")
  branch=$(qqq_worktree_branch_for "$slug")
  while IFS=$'\t' read -r path entry_branch phys; do
    if [[ "$entry_branch" == "$branch" ]]; then
      if [[ "$phys" == "yes" ]]; then
        printf '%s\tlive\n' "$path"
      else
        printf '%s\tghost\n' "$path"
      fi
      return 0
    fi
  done < <(qqq_list_worktrees "$leader_repo")
  if qqq_branch_exists "$leader_repo" "$branch" any; then
    printf '\tbranch-only\n'
  else
    printf '\tnone\n'
  fi
}

qqq_human_age_from_epoch() {
  local epoch="${1:-0}" now delta
  now=$(date +%s)
  (( epoch > 0 )) || {
    printf '?'
    return 0
  }
  delta=$(( now - epoch ))
  (( delta < 0 )) && delta=0
  if (( delta < 3600 )); then
    printf '%dm' $(( delta / 60 ))
  elif (( delta < 86400 )); then
    printf '%dh' $(( delta / 3600 ))
  else
    printf '%dd' $(( delta / 86400 ))
  fi
}

qqq_session_picker_label() {
  local session_dir="$1" mtime="$2" wt_state="$3" lock_present="$4"
  local name label age
  name=$(basename "$session_dir")
  label="${name}$(qqq_session_list_suffix "$session_dir")"
  if qqq_session_is_legacy_blocked "$session_dir"; then
    label+=" [legacy-blocked]"
  fi
  case "$wt_state" in
    ghost)       label+=" [ghost]" ;;
    branch-only) label+=" [branch-only]" ;;
  esac
  [[ "$lock_present" == "yes" ]] && label+=" [locked]"
  age=$(qqq_human_age_from_epoch "$mtime")
  printf '%s · %s' "$label" "$age"
}

qqq_emit_session_row() {
  # Output:
  # <display_label>\t<full_path>\t<picker_scope>\t<merge_status>\t<wt_state>\t<wt_path>\t<lock_present>\t<lock_pid>
  local session_dir="$1" mtime="$2" picker_scope="$3"
  local leader_repo="${4:-}" merge_status status_line wt_path wt_state lock_info lock_present lock_pid label
  if [[ -z "$leader_repo" ]]; then
    leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
      || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
      || leader_repo=""
  fi
  merge_status=$(qqq_session_merge_display_status "$session_dir" 2>/dev/null || printf '')
  status_line=$(qqq_session_worktree_status "$session_dir" "$leader_repo")
  wt_path="${status_line%$'\t'*}"
  wt_state="${status_line##*$'\t'}"
  wt_state="${wt_state%$'\n'}"
  lock_info=$(qqq_session_lock_info "$session_dir")
  lock_present="${lock_info%%$'\t'*}"
  lock_info="${lock_info#*$'\t'}"
  lock_pid="${lock_info%%$'\t'*}"
  label=$(qqq_session_picker_label "$session_dir" "$mtime" "$wt_state" "$lock_present")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$session_dir" "$picker_scope" "$merge_status" "$wt_state" "$wt_path" "$lock_present" "$lock_pid"
}

# ---------------------------------------------------------------------------
# Session management
# ---------------------------------------------------------------------------

ensure_works_dir() {
  mkdir -p "$QQQ_WORKS_DIR"
}

list_sessions() {
  # Hybrid glob: launch-cwd claude-works/ + launch-relative worktree claude-works/.
  # Output:
  # <display_label>\t<full_path>\t<picker_scope>\t<merge_status>\t<wt_state>\t<wt_path>\t<lock_present>\t<lock_pid>
  # (mtime-desc, slug-deduped)
  local scope="${1:-active}"
  local dir mtime dedupe_key bucket_scope
  {
    local leader_repo bucket launch_rel
    if [[ "$scope" == "active" || "$scope" == "all" ]]; then
      for dir in "$QQQ_WORKS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        bucket_scope=$(qqq_picker_session_scope "${dir%/}") || continue
        [[ "$scope" == "all" || "$bucket_scope" == "$scope" ]] || continue
        mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
        dedupe_key=$(qqq_session_dedupe_key "${dir%/}")
        printf '%s\t%s\t' "$mtime" "$dedupe_key"
        qqq_emit_session_row "${dir%/}" "$mtime" "$bucket_scope"
        printf '\n'
      done
    fi
    if leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null); then
      bucket=$(qqq_worktree_bucket_dir "$leader_repo")
      launch_rel=$(qqq_launch_rel_from_repo "$leader_repo" 2>/dev/null || printf '')
      if [[ -d "$bucket" ]]; then
        if [[ -n "$launch_rel" ]]; then
          if [[ "$scope" == "active" || "$scope" == "all" ]]; then
            for dir in "$bucket"/*/"$launch_rel"/claude-works/*/; do
              [[ -d "$dir" ]] || continue
              bucket_scope=$(qqq_picker_session_scope "${dir%/}") || continue
              [[ "$scope" == "all" || "$bucket_scope" == "$scope" ]] || continue
              mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
              dedupe_key=$(qqq_session_dedupe_key "${dir%/}")
              printf '%s\t%s\t' "$mtime" "$dedupe_key"
              qqq_emit_session_row "${dir%/}" "$mtime" "$bucket_scope" "$leader_repo"
              printf '\n'
            done
          fi
          if [[ "$scope" == "completed" || "$scope" == "all" ]]; then
            for dir in "$bucket"/*/"$launch_rel"/claude-works-completed/*/; do
              [[ -d "$dir" ]] || continue
              bucket_scope=$(qqq_picker_session_scope "${dir%/}") || continue
              [[ "$scope" == "all" || "$bucket_scope" == "$scope" ]] || continue
              mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
              dedupe_key=$(qqq_session_dedupe_key "${dir%/}")
              printf '%s\t%s\t' "$mtime" "$dedupe_key"
              qqq_emit_session_row "${dir%/}" "$mtime" "$bucket_scope" "$leader_repo"
              printf '\n'
            done
          fi
        else
          if [[ "$scope" == "active" || "$scope" == "all" ]]; then
            for dir in "$bucket"/*/claude-works/*/; do
              [[ -d "$dir" ]] || continue
              bucket_scope=$(qqq_picker_session_scope "${dir%/}") || continue
              [[ "$scope" == "all" || "$bucket_scope" == "$scope" ]] || continue
              mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
              dedupe_key=$(qqq_session_dedupe_key "${dir%/}")
              printf '%s\t%s\t' "$mtime" "$dedupe_key"
              qqq_emit_session_row "${dir%/}" "$mtime" "$bucket_scope" "$leader_repo"
              printf '\n'
            done
          fi
          if [[ "$scope" == "completed" || "$scope" == "all" ]]; then
            for dir in "$bucket"/*/claude-works-completed/*/; do
              [[ -d "$dir" ]] || continue
              bucket_scope=$(qqq_picker_session_scope "${dir%/}") || continue
              [[ "$scope" == "all" || "$bucket_scope" == "$scope" ]] || continue
              mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
              dedupe_key=$(qqq_session_dedupe_key "${dir%/}")
              printf '%s\t%s\t' "$mtime" "$dedupe_key"
              qqq_emit_session_row "${dir%/}" "$mtime" "$bucket_scope" "$leader_repo"
              printf '\n'
            done
          fi
        fi
      fi
      # Completed archive — launch cwd claude-works-completed/<date_slug>/
      if [[ ("$scope" == "completed" || "$scope" == "all") && -d "$QQQ_COMPLETED_DIR" ]]; then
        for dir in "$QQQ_COMPLETED_DIR"/*/; do
          [[ -d "$dir" ]] || continue
          bucket_scope=$(qqq_picker_session_scope "${dir%/}") || continue
          [[ "$scope" == "all" || "$bucket_scope" == "$scope" ]] || continue
          mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo 0)
          dedupe_key=$(qqq_session_dedupe_key "${dir%/}")
          printf '%s\t%s\t' "$mtime" "$dedupe_key"
          qqq_emit_session_row "${dir%/}" "$mtime" "$bucket_scope" "$leader_repo"
          printf '\n'
        done
      fi
    fi
  } | sort -rn -t$'\t' -k1,1 \
    | awk -F'\t' '!seen[$2]++ { print $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $10 }'
}

session_preview() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    printf '(session path missing: %s)\n' "${dir:-<empty>}"
    return
  fi
  printf '%s\n\n' "$dir"

  local leader_repo status_line wt_path wt_state wt_root merge_status lock_info lock_present lock_pid lock_alive
  local picker_scope discard_plan discard_kind force_required branch local_branch remote_branch impact_summary
  local legacy_blocked=no
  leader_repo=$(qqq_leader_repo_from "$dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || leader_repo=""
  status_line=$(qqq_session_worktree_status "$dir" "$leader_repo")
  wt_path="${status_line%$'\t'*}"
  wt_state="${status_line##*$'\t'}"
  wt_state="${wt_state%$'\n'}"
  wt_root=$(qqq_session_dir_worktree "$dir")
  merge_status=$(qqq_session_merge_display_status "$dir")
  lock_info=$(qqq_session_lock_info "$dir")
  lock_present="${lock_info%%$'\t'*}"
  lock_info="${lock_info#*$'\t'}"
  lock_pid="${lock_info%%$'\t'*}"
  lock_alive="${lock_info##*$'\t'}"
  lock_alive="${lock_alive%$'\n'}"
  picker_scope=$(qqq_picker_session_scope "$dir" 2>/dev/null || printf 'active')
  discard_plan=$(qqq_session_discard_plan "$dir" "$picker_scope")
  discard_kind=$(qqq_tsv_field "$discard_plan" 1)
  force_required=$(qqq_tsv_field "$discard_plan" 2)
  merge_status=$(qqq_tsv_field "$discard_plan" 4)
  branch=$(qqq_tsv_field "$discard_plan" 6)
  local_branch=$(qqq_tsv_field "$discard_plan" 9)
  remote_branch=$(qqq_tsv_field "$discard_plan" 10)
  impact_summary=$(qqq_tsv_field "$discard_plan" 14)
  qqq_session_is_legacy_blocked "$dir" && legacy_blocked=yes

  if [[ "$legacy_blocked" == "yes" ]]; then
    printf 'status: [legacy-blocked] — this pre-worktree session cannot be resumed\n'
    printf 'note: discard is allowed, but resume is blocked. Create a new session instead.\n\n'
  else
    case "$merge_status" in
      push_pending)
        printf 'status: [push-pending] — local merge exists; resume with `qqq --session %s --merge-resume-push`\n\n' "$dir"
        ;;
      completed)
        if [[ -z "$wt_root" ]]; then
          printf 'status: [completed] — archived session (read-only)\n\n'
        else
          printf 'status: [completed] — archived worktree copy\n\n'
        fi
        ;;
      archived)
        printf 'status: [archived] — session moved to completed path; merge not finished yet\n\n'
        ;;
      rebased|merged_local)
        printf 'status: [%s] — merge recovery state saved in .qqq/merge-state.json\n\n' "${merge_status//_/-}"
        ;;
    esac
  fi

  case "$wt_state" in
    live)        printf 'worktree: %s  [active]\n' "$wt_path" ;;
    ghost)       printf 'worktree: %s  [ghost: path missing]\n' "$wt_path" ;;
    branch-only) printf 'worktree: (branch only — no checkout)\n' ;;
    none)        printf 'worktree: (none)\n' ;;
    no-repo)     printf 'worktree: (not inside a git repo)\n' ;;
  esac
  printf '\n'

  printf 'Phase progress:\n'
  for f in phase1-spec.md phase1-ui-outline.md phase1-ui-outline.html phase1-nltp.md \
           phase1-tech-spec.md \
           phase2-code-plan.md phase2-review-log.md phase2-review-state.json \
           phase3-implement-log.md; do
    if [[ -f "$dir/$f" ]]; then
      printf '  [ok] %s\n' "$f"
    else
      printf '  [  ] %s\n' "$f"
    fi
  done
  local reviews plan_reviews
  reviews=$(ls -1 "$dir"/phase3-codex-review-*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$reviews" != "0" ]]; then
    printf '  codex review rounds: %s\n' "$reviews"
  fi
  plan_reviews=$(ls -1 "$dir"/phase2-review-round-*.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$plan_reviews" != "0" ]]; then
    printf '  plan review rounds: %s\n' "$plan_reviews"
  fi
  # phase1-ui-outline.html is optional — inform but do not gate.
  if [[ -f "$dir/phase1-ui-outline.md" && ! -f "$dir/phase1-ui-outline.html" ]]; then
    printf '\n  note: phase1-ui-outline.html missing (optional — ignored).\n'
  fi

  printf '\nMaintenance:\n'
  if [[ "$lock_present" == "yes" ]]; then
    if [[ -n "$lock_pid" ]]; then
      printf '  lock: present (pid %s, alive=%s)\n' "$lock_pid" "$lock_alive"
    else
      printf '  lock: present\n'
    fi
  else
    printf '  lock: none\n'
  fi
  if qqq_merge_status_requires_recovery_warning "$merge_status"; then
    printf '  recovery: FORCE required to discard [%s] state\n' "${merge_status//_/-}"
  fi
  if [[ "$legacy_blocked" == "yes" ]]; then
    printf '  resume: blocked (worktree-first 이전 형식)\n'
    printf '  discard: discard only; linked worktree cleanup is never attempted\n'
  fi
  if [[ "$discard_kind" == "blocked" ]]; then
    printf '  discard: archive delete unsupported from picker\n'
  elif [[ "$picker_scope" != "completed" ]]; then
    printf '  discard: %s\n' "$impact_summary"
    if [[ "$remote_branch" == "yes" ]]; then
      printf '  discard: remote branch present (origin/%s) — extra confirm required\n' "$branch"
    fi
    if [[ "$force_required" == "yes" ]]; then
      printf '  discard: FORCE confirmation required\n'
    fi
  fi

  # Last run summary — exit code + timestamp from .qqq/agent-<role>.{start,exit}.
  # Overlay phase2/3 review verdicts when the corresponding artifacts exist.
  if [[ -d "$dir/.qqq" ]]; then
    local lr_role lr_start_file lr_exit_file lr_started lr_exit_line
    local lr_exit_code lr_exited lr_status lr_extra lr_has_any=0 lr_verdict
    for lr_role in req-clarifier ui-outliner nltp-interviewer tech-interviewer code-planner code-implementer; do
      lr_start_file="$dir/.qqq/agent-${lr_role}.start"
      lr_exit_file="$dir/.qqq/agent-${lr_role}.exit"
      [[ -f "$lr_start_file" ]] || continue
      if (( lr_has_any == 0 )); then
        printf '\nLast run:\n'
        lr_has_any=1
      fi
      lr_started=$(head -n 1 "$lr_start_file" 2>/dev/null)
      if [[ -f "$lr_exit_file" && "$lr_exit_file" -nt "$lr_start_file" ]]; then
        lr_exit_line=$(head -n 1 "$lr_exit_file" 2>/dev/null)
        lr_exit_code="${lr_exit_line%%$'\t'*}"
        lr_exited="${lr_exit_line#*$'\t'}"
        if [[ "$lr_exit_code" == "0" ]]; then
          lr_status='ok '
        else
          lr_status='ERR'
        fi
        lr_extra="exit=${lr_exit_code} at ${lr_exited}"
      elif [[ -f "$lr_exit_file" ]]; then
        # exit file exists but older than start — leftover from a prior run.
        lr_status='...'
        lr_extra="running or aborted (started ${lr_started})"
      else
        lr_status='...'
        lr_extra="running or aborted (started ${lr_started})"
      fi
      case "$lr_role" in
        code-planner)
          lr_verdict=$(qqq_json_string_field "$dir/phase2-review-state.json" "final_verdict" 2>/dev/null)
          [[ -n "$lr_verdict" ]] && lr_extra+=" · review: ${lr_verdict}"
          ;;
        code-implementer)
          if [[ -f "$dir/phase3-implement-log.md" ]]; then
            lr_verdict=$(grep -E '^Final reviewer verdict:' "$dir/phase3-implement-log.md" 2>/dev/null \
              | tail -n 1 | sed 's/^Final reviewer verdict:[[:space:]]*//')
            [[ -n "$lr_verdict" ]] && lr_extra+=" · review: ${lr_verdict}"
          fi
          ;;
      esac
      printf '  [%s] %-18s %s\n' "$lr_status" "$lr_role" "$lr_extra"
    done
  fi

  # Agent window tail — shows last lines of any live agent window for this
  # session so the user can see the most recent output (success message,
  # error trace, prompt-waiting state) without leaving the picker.
  if [[ -n "${TMUX_SESSION_NAME:-}" ]] && tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    local agent_slug agent_role agent_win agent_has_any=0
    agent_slug=$(qqq_window_slug_from_session_dir "$dir")
    for agent_role in req-clarifier ui-outliner nltp-interviewer tech-interviewer code-planner code-implementer rebase-resolver; do
      agent_win="${agent_slug}:${agent_role}"
      if tmux list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qxF "$agent_win"; then
        if (( agent_has_any == 0 )); then
          printf '\nAgent window tail:\n'
          agent_has_any=1
        fi
        printf '\n--- [%s] last 12 lines ---\n' "$agent_role"
        tmux capture-pane -p -t "$TMUX_SESSION_NAME:$agent_win" -S -12 2>/dev/null
      fi
    done
  fi
}

export -f session_preview \
          qqq_leader_repo_from qqq_repo_slug_from \
          qqq_slug_from_session_dir qqq_window_slug_from_session_dir \
          qqq_session_dir_worktree \
          qqq_session_is_legacy_blocked qqq_print_legacy_session_blocked_message \
          qqq_assert_session_resumable \
          qqq_session_worktree_status qqq_worktree_bucket_dir \
          qqq_worktree_path_for qqq_worktree_branch_for \
          qqq_list_worktrees qqq_branch_exists \
          qqq_picker_session_scope qqq_picker_should_include_session \
          qqq_pid_is_alive qqq_session_lock_info \
          qqq_tsv_field qqq_fzf qqq_read_prompt \
          qqq_human_age_from_epoch qqq_session_picker_label \
          qqq_merge_status_requires_recovery_warning qqq_session_discard_plan \
          qqq_json_unescape qqq_json_read_string_key \
          qqq_merge_state_path qqq_merge_state_get qqq_merge_state_status \
          qqq_session_merge_display_status qqq_session_dedupe_key \
          qqq_launch_cwd qqq_launch_rel_from_repo
export QQQ_WORKS_DIR QQQ_COMPLETED_DIR

validate_session_path() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    printf '[qqq] --session path does not exist: %s\n' "$path" >&2
    return 1
  fi
  local abs
  abs=$(cd "$path" && pwd)
  local base
  base=$(basename "$abs")
  if [[ "$abs" != */claude-works/* && ! "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_ ]]; then
    printf '[qqq] --session path is not a qqq session (must live under claude-works/ or have YYYY-MM-DD_ prefix): %s\n' \
      "$path" >&2
    return 1
  fi
  qqq_assert_session_resumable "$abs" || return 1
  return 0
}

qqq_repo_default_branch() {
  local repo_root="$1"
  local default_branch="" cand
  default_branch=$(qqq_origin_default_branch "$repo_root" 2>/dev/null) || default_branch=""
  if [[ -z "$default_branch" ]]; then
    for cand in main master trunk; do
      if qqq_branch_exists "$repo_root" "$cand" remote; then
        default_branch="$cand"
        break
      fi
    done
  fi
  [[ -n "$default_branch" ]] || return 1
  printf '%s' "$default_branch"
}

qqq_branch_sync_status() {
  # Output: missing-local | missing-remote | synced | ahead | behind | diverged
  local repo_root="$1" branch="$2"
  if ! qqq_branch_exists "$repo_root" "$branch" remote; then
    printf 'missing-remote'
    return 0
  fi
  if ! qqq_branch_exists "$repo_root" "$branch" local; then
    printf 'missing-local'
    return 0
  fi
  local ahead behind
  ahead=$(git -C "$repo_root" rev-list --count "origin/$branch..$branch" 2>/dev/null || echo 0)
  behind=$(git -C "$repo_root" rev-list --count "$branch..origin/$branch" 2>/dev/null || echo 0)
  if (( ahead == 0 && behind == 0 )); then
    printf 'synced'
  elif (( ahead > 0 && behind == 0 )); then
    printf 'ahead'
  elif (( ahead == 0 && behind > 0 )); then
    printf 'behind'
  else
    printf 'diverged'
  fi
}

qqq_repo_mr_template_count() {
  local repo_root="$1" tmpl_dir count=0
  tmpl_dir="$repo_root/.gitlab/merge_request_templates"
  if [[ -d "$tmpl_dir" ]]; then
    count=$(find "$tmpl_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf '%s' "$count"
}

qqq_repo_dev_main_mr_status() {
  # Output:
  # <ready>\t<target_branch>\t<dev_branch>\t<ahead_count>\t<local_sync>\t<template_count>\t<glab_installed>\t<glab_auth>\t<reason>
  local repo_root="$1"
  local ready="no" target_branch="main" dev_branch="" ahead_count="0" local_sync="missing-remote"
  local template_count="0" glab_installed="no" glab_auth="not-preflighted" reason=""
  dev_branch=$(qqq_origin_dev_branch)
  template_count=$(qqq_repo_mr_template_count "$repo_root")
  command -v glab >/dev/null 2>&1 && glab_installed="yes"
  if ! qqq_branch_exists "$repo_root" "$target_branch" remote; then
    reason="origin-main-missing"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ready" "$target_branch" "$dev_branch" "$ahead_count" "$local_sync" "$template_count" "$glab_installed" "$glab_auth" "$reason"
    return 0
  fi
  if ! qqq_branch_exists "$repo_root" "$dev_branch" remote; then
    reason="origin-dev-missing"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ready" "$target_branch" "$dev_branch" "$ahead_count" "$local_sync" "$template_count" "$glab_installed" "$glab_auth" "$reason"
    return 0
  fi
  ahead_count=$(git -C "$repo_root" rev-list --count "origin/$target_branch..origin/$dev_branch" 2>/dev/null || echo 0)
  local_sync=$(qqq_branch_sync_status "$repo_root" "$dev_branch")
  if (( ahead_count == 0 )); then
    reason="nothing-to-mr"
  elif [[ "$glab_installed" != "yes" ]]; then
    reason="glab-missing"
  elif [[ "$local_sync" != "synced" ]]; then
    reason="local-dev-not-synced"
  else
    ready="yes"
    reason="ready"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ready" "$target_branch" "$dev_branch" "$ahead_count" "$local_sync" "$template_count" "$glab_installed" "$glab_auth" "$reason"
}

repo_action_preview() {
  local action="$1"
  local leader_repo status_line ready target_branch dev_branch ahead_count local_sync template_count
  local glab_installed glab_auth reason
  leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) || {
    printf 'repository: (not inside a git repo)\n'
    return 0
  }
  printf 'repository: %s\n\n' "$leader_repo"
  case "$action" in
    dev-main-mr)
      status_line=$(qqq_repo_dev_main_mr_status "$leader_repo")
      ready=$(qqq_tsv_field "$status_line" 1)
      target_branch=$(qqq_tsv_field "$status_line" 2)
      dev_branch=$(qqq_tsv_field "$status_line" 3)
      ahead_count=$(qqq_tsv_field "$status_line" 4)
      local_sync=$(qqq_tsv_field "$status_line" 5)
      template_count=$(qqq_tsv_field "$status_line" 6)
      glab_installed=$(qqq_tsv_field "$status_line" 7)
      glab_auth=$(qqq_tsv_field "$status_line" 8)
      reason=$(qqq_tsv_field "$status_line" 9)
      printf 'action: create %s -> %s MR\n' "$dev_branch" "$target_branch"
      printf 'source of truth: origin/%s\n' "$dev_branch"
      printf 'origin/%s ahead of origin/%s: %s commit(s)\n' "$dev_branch" "$target_branch" "$ahead_count"
      printf 'local %s: %s\n' "$dev_branch" "$local_sync"
      printf 'MR templates: %s\n' "$template_count"
      printf 'glab installed: %s\n' "$glab_installed"
      printf 'glab auth: %s\n' "$glab_auth"
      printf 'ready: %s\n' "$ready"
      case "$reason" in
        ready)                    printf 'note: local %s matches origin/%s; safe to create MR.\n' "$dev_branch" "$dev_branch" ;;
        nothing-to-mr)            printf 'note: origin/%s has no commits beyond origin/%s.\n' "$dev_branch" "$target_branch" ;;
        origin-main-missing)      printf 'note: origin/main does not exist.\n' ;;
        origin-dev-missing)       printf 'note: origin/%s does not exist.\n' "$dev_branch" ;;
        glab-missing)             printf 'note: install `glab` first.\n' ;;
        local-dev-not-synced)     printf 'note: sync local %s to origin/%s before creating the MR.\n' "$dev_branch" "$dev_branch" ;;
      esac
      if [[ "$glab_installed" == "yes" ]]; then
        printf 'note: auth is not preflighted here; `glab mr create` will validate it when you run the action.\n'
      fi
      if qqq_branch_exists "$leader_repo" "$target_branch" remote && qqq_branch_exists "$leader_repo" "$dev_branch" remote && (( ahead_count > 0 )); then
        printf '\ncommits in origin/%s not in origin/%s:\n' "$dev_branch" "$target_branch"
        git -C "$leader_repo" log --pretty='  %h %s' "origin/${target_branch}..origin/${dev_branch}" 2>/dev/null | head -10
      fi
      ;;
    *)
      printf 'unknown repo action: %s\n' "$action"
      ;;
  esac
}

export -f repo_action_preview \
          qqq_repo_default_branch qqq_branch_sync_status \
          qqq_repo_mr_template_count qqq_repo_dev_main_mr_status

select_session_scope() {
  local choice
  choice=$(
    printf '%s\n' \
      $'active\tActive Sessions\tIn-progress and recovery sessions only' \
      $'completed\tCompleted Sessions\tArchived read-only sessions only' \
      $'all\tAll Sessions\tEverything in one list' \
      $'repo\tRepository Actions\tRepo-level actions like dev -> main merge request' \
      $'new\tNew Session\tCreate a new linked worktree session' \
    | qqq_fzf \
        --prompt='qqq scope > ' \
        --header='Enter to choose a session scope · Ctrl-C to abort' \
        --height=35% \
        --delimiter=$'\t' --with-nth=2,3
  ) || return 1
  printf '%s' "${choice%%$'\t'*}"
}

select_repo_action() {
  local choice
  choice=$(
    printf '%s\n' \
      $'dev-main-mr\tCreate dev -> main MR\tCreate a GitLab merge request from origin/dev to origin/main' \
    | qqq_fzf \
        --prompt='qqq repo > ' \
        --header='Enter to run a repository action · Ctrl-C to go back · preview shows readiness' \
        --height=30% \
        --preview "bash -c 'repo_action_preview \"\$1\"' _ {1}" \
        --preview-window=right:60%,wrap \
        --delimiter=$'\t' --with-nth=2,3
  ) || return 1
  printf '%s' "${choice%%$'\t'*}"
}

run_repo_action() {
  local action="${1:-}"
  case "$action" in
    dev-main-mr)
      action_dev_mr_create "$PWD"
      ;;
    *)
      printf '[qqq] unknown repo action: %s\n' "$action" >&2
      return 1
      ;;
  esac
}

select_session() {
  local scope choice header prompt sessions key row selected_label selected_path repo_action
  while :; do
    scope=$(select_session_scope) || return 1
    if [[ "$scope" == "new" ]]; then
      create_new_session
      return
    fi
    if [[ "$scope" == "repo" ]]; then
      repo_action=$(select_repo_action) || continue
      run_repo_action "$repo_action"
      continue
    fi

    case "$scope" in
      active)
        prompt='qqq active > '
        header=$'Enter to select · Delete to discard highlighted session · Ctrl-C to go back\nscope: active sessions'
        ;;
      completed)
        prompt='qqq completed > '
        header=$'Enter to select · Delete is blocked for archive rows · Ctrl-C to go back\nscope: completed sessions (read-only)'
        ;;
      *)
        prompt='qqq all > '
        header=$'Enter to select · Delete to discard highlighted active session · Ctrl-C to go back\nscope: all sessions'
        ;;
    esac

    while :; do
      sessions=$(list_sessions "$scope")
      if [[ -z "$sessions" ]]; then
        printf '[qqq] no %s sessions found.\n' "$scope" >&2
        break
      fi

      choice=$(printf '%s\n' "$sessions" | qqq_fzf \
            --prompt="$prompt" \
            --header="$header" \
            --height=50% \
            --delimiter=$'\t' --with-nth=1 \
            --expect=enter,del \
            --preview "bash -c 'session_preview \"\$1\"' _ {2}" \
            --preview-window=right:55%) || break

      if [[ "$choice" == *$'\n'* ]]; then
        key="${choice%%$'\n'*}"
        row="${choice#*$'\n'}"
      else
        key="enter"
        row="$choice"
      fi
      [[ -n "$row" ]] || continue
      [[ -n "$key" ]] || key="enter"

      if [[ "$key" == "del" ]]; then
        qqq_picker_discard_session "$row"
        continue
      fi

      if [[ "$row" == *$'\t'* ]]; then
        selected_label=$(qqq_tsv_field "$row" 1)
        selected_path=$(qqq_tsv_field "$row" 2)
        if ! qqq_assert_session_resumable "$selected_path"; then
          continue
        fi
        printf '%s' "$selected_path"
      else
        printf '%s/%s' "$QQQ_WORKS_DIR" "$row"
      fi
      return
    done
  done
}

create_new_session() {
  local slug
  qqq_read_prompt '[qqq] feature slug (kebab-case): ' slug || return 1
  slug=$(printf '%s' "$slug" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')
  if [[ -z "$slug" ]]; then
    printf '[qqq] empty slug; aborting.\n' >&2
    return 1
  fi
  local session_name
  session_name="$(date +%Y-%m-%d)_${slug}"
  qqq_bootstrap_session_worktree "$session_name"
}

# ---------------------------------------------------------------------------
# Phase detection
# ---------------------------------------------------------------------------

qqq_sha256_file() {
  local path="$1" digest=""
  [[ -f "$path" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$path" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$path" | awk '{print $1}')
  else
    return 1
  fi
  [[ -n "$digest" ]] || return 1
  printf 'sha256:%s' "$digest"
}

qqq_json_string_field() {
  local path="$1" field="$2"
  [[ -f "$path" ]] || return 1
  sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$path" | head -n 1
}
export -f qqq_json_string_field

qqq_phase2_review_completed() {
  local sess="$1"
  local plan="$sess/phase2-code-plan.md"
  local review_state="$sess/phase2-review-state.json"
  local completion_flag final_verdict current_fingerprint reviewed_fingerprint
  [[ -f "$plan" ]] || return 1

  # Backward-compatible fallback for older sessions created before the human
  # approval gate was removed.
  if grep -q '^Status: Approved by user' "$plan" 2>/dev/null; then
    return 0
  fi

  [[ -f "$review_state" ]] || return 1
  completion_flag=$(sed -nE 's/.*"review_loop_completed"[[:space:]]*:[[:space:]]*(true|false).*/\1/p' "$review_state" | head -n 1)
  [[ "$completion_flag" == "true" ]] || return 1
  final_verdict=$(qqq_json_string_field "$review_state" "final_verdict")
  case "$final_verdict" in
    OKAY|"Ready with caveats") ;;
    *) return 1 ;;
  esac
  current_fingerprint=$(qqq_sha256_file "$plan") || return 1
  reviewed_fingerprint=$(qqq_json_string_field "$review_state" "last_input_fingerprint")
  [[ -n "$reviewed_fingerprint" && "$current_fingerprint" == "$reviewed_fingerprint" ]]
}

qqq_guard_phase2_review_completed() {
  local sess="$1"
  if ! qqq_phase2_review_completed "$sess"; then
    printf '[qqq] phase2 review loop is not complete for phase2-code-plan.md. Re-run code-planner until phase2-review-state.json records the final review verdict.\n' >&2
    return 1
  fi
  return 0
}

# Returns one of:
#   req-clarifier ui-outliner nltp-interviewer tech-interviewer code-planner code-implementer resolve-rebase-conflict worktree-merge done
detect_next_phase() {
  local sess="$1"
  local merge_status=""
  merge_status=$(qqq_session_merge_display_status "$sess")
  if [[ "$merge_status" == "push_pending" ]]; then
    echo "merge-resume-push"
    return
  fi

  local leader_repo=""
  leader_repo=$(qqq_leader_repo_from "$sess" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || leader_repo=""
  if [[ -n "$leader_repo" ]]; then
    local wt_root
    wt_root=$(qqq_session_dir_worktree "$sess")
    if [[ -n "$wt_root" ]] && qqq_worktree_rebase_in_progress "$wt_root"; then
      echo "resolve-rebase-conflict"
      return
    fi
    if [[ "$sess" == */claude-works-completed/* && "$merge_status" == "completed" ]]; then
      echo "done"
      return
    fi
  fi

  if [[ ! -f "$sess/phase1-spec.md" ]]; then
    echo "req-clarifier"
  elif [[ ! -f "$sess/phase1-tech-spec.md" ]]; then
    echo "tech-interviewer"
  elif [[ ! -f "$sess/phase2-code-plan.md" ]]; then
    echo "code-planner"
  elif ! qqq_phase2_review_completed "$sess"; then
    echo "code-planner"
  elif [[ ! -f "$sess/phase3-implement-log.md" ]]; then
    echo "code-implementer"
  else
    echo "worktree-merge"
  fi
}

phase_title() {
  case "$1" in
    req-clarifier)    echo 'Phase1 T1 · req-clarifier' ;;
    ui-outliner)      echo 'Phase1 T2 · ui-outliner' ;;
    nltp-interviewer) echo 'Phase1 T3 · nltp-interviewer' ;;
    tech-interviewer) echo 'Phase1 T4 · tech-interviewer' ;;
    code-planner)     echo 'Phase2 T1 · code-planner' ;;
    code-implementer) echo 'Phase3 T1 · code-implementer' ;;
    resolve-rebase-conflict) echo 'Recovery · resolve rebase conflict' ;;
    merge-resume-push) echo 'Recovery · resume pending push' ;;
    worktree-open)    echo 'Worktree · open shell' ;;
    worktree-merge)   echo 'Worktree · merge session branch' ;;
    worktree-remove)  echo 'Worktree · remove / clean up' ;;
    done)             echo 'Completed · read-only session' ;;
    rewind)           echo 'Maintenance · rewind artifacts' ;;
    view-artifacts)   echo 'Browse · view artifacts' ;;
    open-session-dir) echo 'Browse · open session dir' ;;
    back-to-session-list) echo 'Navigation · back to session list' ;;
    *)                echo "$1" ;;
  esac
}

phase_desc() {
  case "$1" in
    req-clarifier)    echo 'Clarify the requirement and write phase1-spec.md.' ;;
    ui-outliner)      echo 'Draft a minimal UI outline and save phase1-ui-outline.md/html.' ;;
    nltp-interviewer) echo 'Draft the Korean Gherkin NLTP in phase1-nltp.md.' ;;
    tech-interviewer) echo 'Lock the technical spec in phase1-tech-spec.md.' ;;
    code-planner)     echo 'Build the reviewed implementation plan in phase2-code-plan.md.' ;;
    code-implementer) echo 'Execute the plan and write phase3-implement-log.md.' ;;
    resolve-rebase-conflict) echo 'Resume and resolve an in-progress worktree rebase conflict.' ;;
    merge-resume-push) echo 'Retry the saved push after a prior merge completed locally.' ;;
    worktree-open)    echo 'Open a tmux shell window rooted at the current worktree.' ;;
    worktree-merge)   echo 'Rebase onto origin/dev, merge the session branch, push, and clean up.' ;;
    worktree-remove)  echo 'Selectively remove the worktree, branch, or remote leftovers.' ;;
    done)             echo 'Completed session. Read-only browsing actions only.' ;;
    rewind)           echo 'Delete later-phase artifacts so you can rerun from an earlier phase.' ;;
    view-artifacts)   echo 'Open a split pane that lists the files in this session directory.' ;;
    open-session-dir) echo 'Open a shell already cd-ed into this session directory.' ;;
    back-to-session-list) echo 'Return to the session picker without running an action.' ;;
    *)                echo '' ;;
  esac
}

phase_status_mark() {
  local sess="$1" opt="$2" suggested="$3"
  if [[ "$opt" == "$suggested" ]]; then
    printf '★'
    return 0
  fi

  local wt_root merge_status
  wt_root=$(qqq_session_dir_worktree "$sess")
  merge_status=$(qqq_session_merge_display_status "$sess")

  case "$opt" in
    req-clarifier)
      [[ -f "$sess/phase1-spec.md" ]] && printf '●' || printf ' '
      ;;
    ui-outliner)
      [[ -f "$sess/phase1-ui-outline.md" ]] && printf '●' || printf ' '
      ;;
    nltp-interviewer)
      [[ -f "$sess/phase1-nltp.md" ]] && printf '●' || printf ' '
      ;;
    tech-interviewer)
      [[ -f "$sess/phase1-tech-spec.md" ]] && printf '●' || printf ' '
      ;;
    code-planner)
      [[ -f "$sess/phase2-code-plan.md" ]] && printf '●' || printf ' '
      ;;
    code-implementer)
      [[ -f "$sess/phase3-implement-log.md" ]] && printf '●' || printf ' '
      ;;
    merge-resume-push)
      [[ "$merge_status" != "push_pending" ]] && [[ -n "$merge_status" ]] && printf '●' || printf ' '
      ;;
    *)
      printf ' '
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Action menu
# ---------------------------------------------------------------------------

select_action() {
  local sess="$1" suggested="$2"
  # Active sessions are worktree-first. Completed (archived) sessions get a
  # read-only menu.
  local leader_repo="" wt_root="" merge_status="" rebase_in_progress=no
  leader_repo=$(qqq_leader_repo_from "$sess" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || leader_repo=""
  if [[ -n "$leader_repo" ]]; then
    wt_root=$(qqq_session_dir_worktree "$sess")
    if [[ -n "$wt_root" ]] && qqq_worktree_rebase_in_progress "$wt_root"; then
      rebase_in_progress=yes
    fi
  fi
  merge_status=$(qqq_session_merge_display_status "$sess")

  local options=()
  if [[ "$sess" == */claude-works-completed/* && "$merge_status" == "completed" ]]; then
    options=(
      view-artifacts
      open-session-dir
    )
  elif [[ "$merge_status" == "push_pending" ]]; then
    options=(
      merge-resume-push
      view-artifacts
      open-session-dir
    )
  else
    options=(
      req-clarifier
      ui-outliner
      nltp-interviewer
      tech-interviewer
      code-planner
      code-implementer
      worktree-open
      worktree-remove
      rewind
      view-artifacts
      open-session-dir
    )
    if [[ "$rebase_in_progress" == "yes" ]]; then
      options=(resolve-rebase-conflict "${options[@]}")
    fi
    if [[ -f "$sess/phase3-implement-log.md" ]]; then
      options+=(worktree-merge)
    fi
  fi

  # Build a "last run: ..." header line from .qqq/agent-<role>.{start,exit}.
  # Picks the most recently launched agent and reports its outcome.
  local last_role="" last_status="" last_extra="" last_run_line=""
  if [[ -d "$sess/.qqq" ]]; then
    local newest="" f
    for f in "$sess"/.qqq/agent-*.start; do
      [[ -f "$f" ]] || continue
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
        newest="$f"
      fi
    done
    if [[ -n "$newest" ]]; then
      last_role=$(basename "$newest" .start)
      last_role="${last_role#agent-}"
      local last_exit_file="$sess/.qqq/agent-${last_role}.exit"
      if [[ -f "$last_exit_file" && "$last_exit_file" -nt "$newest" ]]; then
        local last_line last_code last_at
        last_line=$(head -n 1 "$last_exit_file" 2>/dev/null)
        last_code="${last_line%%$'\t'*}"
        last_at="${last_line#*$'\t'}"
        if [[ "$last_code" == "0" ]]; then
          last_status="ok"
        else
          last_status="ERR"
        fi
        last_extra="exit=${last_code} at ${last_at}"
      else
        last_status="..."
        last_extra="running or aborted"
      fi
      last_run_line=$'\n'"last run: [${last_status}] ${last_role} · ${last_extra}"
    fi
  fi

  local picked
  local preview_cmd
  printf -v preview_cmd "bash -c 'session_preview \"\$1\"' _ %q" "$sess"
  picked=$(
    {
      local opt mark title desc title_line desc_line
      local esc=$'\033'
      for opt in "${options[@]}"; do
        mark=$(phase_status_mark "$sess" "$opt" "$suggested")
        title=$(phase_title "$opt")
        desc=$(phase_desc "$opt")
        title_line="${esc}[1m[${mark}] ${title}${esc}[0m"
        desc_line="    ${esc}[2mabout: ${desc}${esc}[0m"
        printf '%s|%s\n%s\0' "$opt" "$title_line" "$desc_line"
      done
    } | qqq_fzf --read0 --ansi \
          --delimiter='|' --with-nth=2.. --accept-nth=1 \
          --prompt="next > " \
          --header=$'Enter to run · Esc/Ctrl-C to change session\n[★] suggested   [●] done   [ ] available\n'"session: $(basename "$sess")   ·   suggested: ${suggested}${last_run_line}" \
          --height=80% \
          --gap=1 \
          --wrap=word \
          --preview "$preview_cmd" \
          --preview-label=' session ' \
          --preview-window=up:40%,wrap,border-bottom
  ) || return 1
  printf '%s' "$picked"
}

# ---------------------------------------------------------------------------
# Iteration prompt (for code-planner / code-implementer)
# ---------------------------------------------------------------------------

prompt_iterations() {
  local raw
  qqq_read_prompt "[qqq] iterations [$DEFAULT_ITERATIONS]: " raw || return 1
  raw="${raw:-$DEFAULT_ITERATIONS}"
  # 10#$raw forces decimal so inputs like "09" don't trigger bash's octal parser.
  if ! [[ "$raw" =~ ^[0-9]+$ ]] || (( 10#$raw < 1 )); then
    printf '[qqq] invalid iteration value; using default %d\n' "$DEFAULT_ITERATIONS" >&2
    raw="$DEFAULT_ITERATIONS"
  fi
  printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# Input guards
# ---------------------------------------------------------------------------

guard_file() {
  local label="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    printf '[qqq] missing input for this phase (%s): %s\n' "$label" "$path" >&2
    printf '[qqq] run the prior phase first.\n' >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# tmux launch
# ---------------------------------------------------------------------------

ensure_tmux_session() {
  local menu_cmd
  printf -v menu_cmd "clear; printf '[qqq] persistent menu window for %q\\n'; printf '[qqq] qqq returns focus here after each action.\\n'; printf '[qqq] switch to another tmux window when you want to inspect output.\\n'; while :; do sleep 3600; done" \
    "$TMUX_SESSION_NAME"
  if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION_NAME" -n "menu" "$menu_cmd"
    return
  fi
  if ! window_exists "menu"; then
    tmux new-window -d -t "$TMUX_SESSION_NAME:" -n "menu" "$menu_cmd"
  fi
}

window_exists() {
  local win_name="$1"
  # -F treats the pattern as a fixed string so regex metacharacters are inert.
  tmux list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' 2>/dev/null \
    | grep -qxF "$win_name"
}

attach_if_outside() {
  if [[ -n "${TMUX:-}" ]]; then
    return 0
  fi
  tmux attach -t "$TMUX_SESSION_NAME"
}

tmux_menu_hint() {
  local idx
  idx=$(tmux list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_name}\t#{window_index}' 2>/dev/null \
    | awk -F'\t' '$1=="menu" { print $2; exit }')
  if [[ -n "$idx" ]]; then
    printf 'return to menu: Ctrl-b %s (window: menu)' "$idx"
  else
    printf 'return to menu: select tmux window "menu"'
  fi
}

select_menu_window() {
  if window_exists "menu"; then
    tmux select-window -t "$TMUX_SESSION_NAME:menu"
  fi
}

qqq_list_session_agent_windows() {
  local sess="$1"
  tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null || return 0
  local win_slug prefix entry index name role
  win_slug=$(qqq_window_slug_from_session_dir "$sess")
  prefix="${win_slug}:"
  while IFS=$'\t' read -r index name; do
    [[ -n "$index" && -n "$name" ]] || continue
    [[ "$name" == "$prefix"* ]] || continue
    role="${name#"$prefix"}"
    qqq_is_managed_agent_role "$role" || continue
    printf '%s\t%s\t%s\n' "$index" "$role" "$name"
  done < <(tmux list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_index}\t#{window_name}' 2>/dev/null)
}

qqq_format_agent_window_matches() {
  local entries="$1"
  local out="" index role name
  while IFS=$'\t' read -r index role name; do
    [[ -n "$index" && -n "$name" ]] || continue
    [[ -n "$out" ]] && out+=","
    out+="${index}:${name}"
  done <<<"$entries"
  printf '%s' "$out"
}

qqq_print_session_agent_windows() {
  local entries="$1"
  local index role name
  while IFS=$'\t' read -r index role name; do
    [[ -n "$index" && -n "$name" ]] || continue
    printf '  - [%s] %s\n' "$index" "$name"
  done <<<"$entries"
}

qqq_highest_agent_window_index_for_role() {
  local sess="$1" target_role="$2"
  local entries index role name highest=""
  entries=$(qqq_list_session_agent_windows "$sess")
  while IFS=$'\t' read -r index role name; do
    [[ "$role" == "$target_role" ]] || continue
    if [[ -z "$highest" || "$index" -gt "$highest" ]]; then
      highest="$index"
    fi
  done <<<"$entries"
  [[ -n "$highest" ]] && printf '%s' "$highest"
}

qqq_kill_tmux_windows_by_index() {
  local sorted_indexes=()
  local index
  if (( $# == 0 )); then
    return 0
  fi
  while IFS= read -r index; do
    [[ -n "$index" ]] || continue
    sorted_indexes+=("$index")
  done < <(printf '%s\n' "$@" | awk 'NF' | sort -rn)
  for index in "${sorted_indexes[@]}"; do
    [[ -n "$index" ]] || continue
    tmux kill-window -t "$TMUX_SESSION_NAME:$index"
  done
}

qqq_kill_session_agent_windows_by_role() {
  local sess="$1" target_role="$2"
  local entries index role name indexes=()
  entries=$(qqq_list_session_agent_windows "$sess")
  while IFS=$'\t' read -r index role name; do
    [[ "$role" == "$target_role" ]] || continue
    indexes+=("$index")
  done <<<"$entries"
  (( ${#indexes[@]} > 0 )) && qqq_kill_tmux_windows_by_index "${indexes[@]}"
}

qqq_kill_session_agent_windows() {
  local sess="$1"
  local entries index role name indexes=()
  entries=$(qqq_list_session_agent_windows "$sess")
  while IFS=$'\t' read -r index role name; do
    [[ -n "$index" ]] || continue
    indexes+=("$index")
  done <<<"$entries"
  (( ${#indexes[@]} > 0 )) && qqq_kill_tmux_windows_by_index "${indexes[@]}"
}

qqq_focus_session_agent_window() {
  local sess="$1" target_role="$2"
  local index
  index=$(qqq_highest_agent_window_index_for_role "$sess" "$target_role")
  [[ -n "$index" ]] || return 1
  tmux select-window -t "$TMUX_SESSION_NAME:$index"
  attach_if_outside
}

qqq_agent_window_conflict_action_for_log() {
  case "$1" in
    focus-existing) printf 'focus' ;;
    kill-same-role-and-launch) printf 'kill_same_role_and_launch' ;;
    kill-all-and-launch) printf 'kill_all_and_launch' ;;
    launch) printf 'launch' ;;
    cancel) printf 'cancel' ;;
    *) printf '%s' "$1" ;;
  esac
}

qqq_prompt_agent_window_preflight() {
  local sess="$1" target_role="$2" mode="$3" entries="$4"
  local choice=""
  printf '[qqq] existing agent tmux windows for %s:\n' "$(basename "$sess")" >&2
  qqq_print_session_agent_windows "$entries" >&2
  case "$mode" in
    duplicate)
      printf '[qqq] %s already has an open window in this session.\n' "$target_role" >&2
      printf '  1. Focus the existing %s window\n' "$target_role" >&2
      printf '  2. Kill the existing %s window(s) and launch a new one\n' "$target_role" >&2
      printf '  3. Cancel\n' >&2
      while :; do
        qqq_read_prompt "[qqq] select [1/2/3]: " choice || return 1
        case "$choice" in
          1|f|F) printf 'focus-existing'; return 0 ;;
          2|r|R) printf 'kill-same-role-and-launch'; return 0 ;;
          3|c|C) printf 'cancel'; return 0 ;;
        esac
        printf '[qqq] invalid selection: %s\n' "$choice" >&2
      done
      ;;
    non_duplicate)
      printf '[qqq] another agent window is already open for this session.\n' >&2
      printf '  1. Kill all existing agent windows for this session and launch a new %s window\n' "$target_role" >&2
      printf '  2. Launch a new %s window and keep the existing ones\n' "$target_role" >&2
      printf '  3. Cancel\n' >&2
      while :; do
        qqq_read_prompt "[qqq] select [1/2/3]: " choice || return 1
        case "$choice" in
          1|k|K) printf 'kill-all-and-launch'; return 0 ;;
          2|n|N) printf 'launch'; return 0 ;;
          3|c|C) printf 'cancel'; return 0 ;;
        esac
        printf '[qqq] invalid selection: %s\n' "$choice" >&2
      done
      ;;
  esac
}

qqq_agent_window_preflight() {
  local sess="$1" target_role="$2"
  local entries same_role_entries="" index role name mode="none" decision="launch" matched_windows=""
  entries=$(qqq_list_session_agent_windows "$sess")
  if [[ -n "$entries" ]]; then
    while IFS=$'\t' read -r index role name; do
      [[ "$role" == "$target_role" ]] || continue
      same_role_entries+="${index}"$'\t'"${role}"$'\t'"${name}"$'\n'
    done <<<"$entries"
    if [[ -n "$same_role_entries" ]]; then
      mode="duplicate"
      decision=$(qqq_prompt_agent_window_preflight "$sess" "$target_role" "$mode" "$same_role_entries") || return 1
      matched_windows=$(qqq_format_agent_window_matches "$same_role_entries")
    else
      mode="non_duplicate"
      decision=$(qqq_prompt_agent_window_preflight "$sess" "$target_role" "$mode" "$entries") || return 1
      matched_windows=$(qqq_format_agent_window_matches "$entries")
    fi
  fi

  case "$decision" in
    focus-existing)
      qqq_focus_session_agent_window "$sess" "$target_role" || return 1
      ;;
    kill-same-role-and-launch)
      qqq_kill_session_agent_windows_by_role "$sess" "$target_role"
      ;;
    kill-all-and-launch)
      qqq_kill_session_agent_windows "$sess"
      ;;
  esac

  qqq_log_workflow_event "agent_window_conflict" "handled" "$target_role" "$sess" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "target_role" "$target_role" \
    "mode" "$mode" \
    "action" "$(qqq_agent_window_conflict_action_for_log "$decision")" \
    "matched_windows" "$matched_windows"
  printf '%s' "$decision"
}

launch_in_tmux_window() {
  local win_name="$1"
  local shell_cmd="$2"
  local focus_policy="${3:-menu}"
  local exit_file="${4:-}"
  ensure_tmux_session
  local menu_hint hint_quoted wrapped_cmd
  menu_hint=$(tmux_menu_hint)
  printf -v hint_quoted '%q' "$menu_hint"
  if [[ -n "$exit_file" ]]; then
    local exit_file_quoted
    printf -v exit_file_quoted '%q' "$exit_file"
    wrapped_cmd="printf '%s\\n\\n' $hint_quoted; $shell_cmd; rc=\$?; printf '%s\\t%s\\n' \"\$rc\" \"\$(date -Iseconds)\" > $exit_file_quoted 2>/dev/null; printf '\\n[qqq] window kept open. Type exit to close.\\n'; exec $SHELL"
  else
    wrapped_cmd="printf '%s\\n\\n' $hint_quoted; $shell_cmd; printf '\\n[qqq] window kept open. Type exit to close.\\n'; exec $SHELL"
  fi
  if window_exists "$win_name"; then
    local current_cmd
    current_cmd=$(tmux display-message -p -t "$TMUX_SESSION_NAME:$win_name" '#{pane_current_command}' 2>/dev/null || printf '')
    case "$current_cmd" in
      bash|zsh|fish|sh|dash|ksh)
        # Idle shell after a prior agent exited — safe to re-run the command.
        printf '[qqq] window "%s" exists with idle %s — re-injecting command.\n' "$win_name" "$current_cmd"
        tmux send-keys -t "$TMUX_SESSION_NAME:$win_name" "$wrapped_cmd" C-m
        ;;
      *)
        # Something non-shell is running (claude, editor, etc.) — just focus, do not disturb.
        printf '[qqq] window "%s" is busy (%s active) — selecting only. Let it finish (or Ctrl-b & to close) before re-running.\n' \
          "$win_name" "${current_cmd:-unknown}"
        ;;
    esac
  else
    tmux new-window -t "$TMUX_SESSION_NAME:" -n "$win_name" \
      "$wrapped_cmd"
  fi
  case "$focus_policy" in
    menu)
      select_menu_window
      ;;
    target)
      tmux select-window -t "$TMUX_SESSION_NAME:$win_name"
      ;;
  esac
  attach_if_outside
}

# ---------------------------------------------------------------------------
# Action handlers
# ---------------------------------------------------------------------------

run_agent() {
  local sess="$1" agent="$2" injected="${3:-}" prompt_iter="${4:-0}"
  printf '[qqq] action: %s  ·  session: %s\n' "$agent" "$(basename "$sess")" >&2
  local preflight_decision
  preflight_decision=$(qqq_agent_window_preflight "$sess" "$agent") || return 1
  case "$preflight_decision" in
    focus-existing|cancel)
      return 0
      ;;
  esac
  local extra=""
  if [[ "$prompt_iter" == "1" ]]; then
    local iter
    iter=$(prompt_iterations) || return 1
    extra="iterations=$iter"
  fi
  # Track agent run state so the picker/menu can show ✓/✗/… markers.
  mkdir -p "$sess/.qqq" 2>/dev/null
  date -Iseconds > "$sess/.qqq/agent-${agent}.start" 2>/dev/null
  rm -f "$sess/.qqq/agent-${agent}.exit" 2>/dev/null
  local dev_branch
  dev_branch=$(qqq_origin_dev_branch)
  # Launch from the launch-relative cwd in the active checkout so shell commands
  # target the same repo slice where the session artifacts live.
  local launch_cwd
  launch_cwd=$(qqq_agent_launch_cwd_for_session "$sess")
  # Plugin-namespaced agent id (claude CLI expects the fully-qualified name).
  local agent_id="qqq:${agent}"
  local allowed_tools
  allowed_tools="Bash(find *),Bash(ls *),Bash(git status *),Bash(git diff *),Bash(git log *),Bash(dirname *),Bash(basename *),Bash(date *)"
  case "$agent" in
    tech-interviewer)
      allowed_tools+=",mcp__plugin_context7_context7__resolve-library-id,mcp__plugin_context7_context7__query-docs,WebSearch,WebFetch"
      ;;
    # code-planner owns the Phase 2 review loop directly and needs shell access
    # for artifact discovery, fingerprinting, and summary extraction.
    code-planner)
      allowed_tools+=",mcp__plugin_context7_context7__resolve-library-id,mcp__plugin_context7_context7__query-docs,WebSearch,WebFetch,Bash(wc *),Bash(shasum *),Bash(sha256sum *),Bash(head *),Bash(which codex),Bash(codex *),Write(./claude-works/**),Write(../claude-works/**),Write(../../claude-works/**),Write(../../../claude-works/**),Task"
      ;;
    # code-implementer still needs Task for its review loop but no extra shell
    # surface beyond the shared baseline.
    code-implementer)
      allowed_tools+=",Bash(wc *),Bash(which codex),Bash(codex *),Write(./claude-works/**),Write(../claude-works/**),Write(../../claude-works/**),Write(../../../claude-works/**),Task"
      ;;
  esac
  local qqq_plugin_dir="/home/hskim/.claude/plugins/local/hskim-plugins/plugins/qqq"
  local qqq_skill_root="$qqq_plugin_dir/skills"
  local qqq_agent_root="$qqq_plugin_dir/agents"
  local cmd
  printf -v cmd "cd %q && export QQQ_AGENT=%q QQQ_SESSION_DIR=%q QQQ_PHASE=%q QQQ_DEV_BRANCH=%q QQQ_PLUGIN_DIR=%q QQQ_SKILL_ROOT=%q QQQ_AGENT_ROOT=%q && claude --permission-mode bypassPermissions --allowedTools %q --agent %q" \
    "$launch_cwd" "$agent" "$sess" "$agent" "$dev_branch" "$qqq_plugin_dir" "$qqq_skill_root" "$qqq_agent_root" "$allowed_tools" "$agent_id"
  if [[ -n "$injected" && -n "$extra" ]]; then
    cmd+=" '@${injected} ${extra}'"
  elif [[ -n "$injected" ]]; then
    cmd+=" '@${injected}'"
  fi
  printf '[qqq] launching %s in tmux window...\n' "$agent"
  qqq_log_workflow_event "agent_launch" "started" "$agent" "$sess" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "dev_branch" "$dev_branch"
  local win_slug
  win_slug=$(qqq_window_slug_from_session_dir "$sess")
  local focus_policy="menu"
  case "$agent" in
    req-clarifier|ui-outliner|nltp-interviewer|tech-interviewer)
      # Interactive interview agents — jump straight to the agent window so
      # the user can see and respond to the prompt immediately.
      focus_policy="target"
      ;;
  esac
  local exit_file="$sess/.qqq/agent-${agent}.exit"
  launch_in_tmux_window "${win_slug}:${agent}" "$cmd" "$focus_policy" "$exit_file"
}

launch_rebase_conflict_resolver() {
  local session_dir="$1" wt_path="$2" dev_branch="$3"
  local preflight_decision
  preflight_decision=$(qqq_agent_window_preflight "$session_dir" "rebase-resolver") || return 1
  case "$preflight_decision" in
    focus-existing|cancel)
      return 0
      ;;
  esac
  local slug win_name plan args cmd allowed_tools launch_cwd leader_repo
  slug=$(qqq_window_slug_from_session_dir "$session_dir")
  win_name="${slug}:rebase-resolver"
  allowed_tools="Bash(find *),Bash(ls *),Bash(git status *),Bash(git diff *),Bash(git log *),Bash(dirname *),Bash(basename *),Bash(date *)"
  plan="$session_dir/phase2-code-plan.md"
  leader_repo=$(qqq_leader_repo_from "$wt_path" 2>/dev/null || printf '%s' "$wt_path")
  launch_cwd=$(qqq_checkout_exec_cwd "$wt_path" "$leader_repo")
  if [[ -f "$plan" ]]; then
    args="$plan worktree=$wt_path dev_branch=$dev_branch"
  else
    args="$session_dir worktree=$wt_path dev_branch=$dev_branch"
  fi
  printf -v cmd "cd %q && export QQQ_AGENT=%q QQQ_SESSION_DIR=%q QQQ_PHASE=%q QQQ_DEV_BRANCH=%q && claude --permission-mode bypassPermissions --allowedTools %q --agent qqq:rebase-conflict-resolver %q" \
    "$launch_cwd" "rebase-conflict-resolver" "$session_dir" "resolve-rebase-conflict" "$dev_branch" "$allowed_tools" "$args"
  printf '[qqq] launching rebase-conflict-resolver in tmux window...\n'
  qqq_log_workflow_event "agent_launch" "started" "rebase-conflict-resolver" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "worktree_path" "$wt_path" \
    "dev_branch" "$dev_branch"
  launch_in_tmux_window "$win_name" "$cmd"
}

rewind_session() {
  local sess="$1"
  # Warn about running agent windows — rewind removes artifacts but does NOT kill tmux windows,
  # so an active agent can re-create files after they're deleted.
  if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    local entries agent_windows="" index role name
    entries=$(qqq_list_session_agent_windows "$sess")
    while IFS=$'\t' read -r index role name; do
      [[ -n "$name" ]] || continue
      agent_windows+="${name}"$'\n'
    done <<<"$entries"
    if [[ -n "$agent_windows" ]]; then
      printf '[qqq] warning: these agent tmux windows are still open:\n'
      printf '%s' "$agent_windows" | sed 's/^/  - /'
      printf '[qqq] close them first (Ctrl-b & in the window) or the agent may re-create deleted files.\n\n'
    fi
  fi

  local phase_pick
  phase_pick=$({
      printf 'phase1 (redo from scratch — deletes phase1 + phase2 + phase3)\n'
      printf 'phase2 (redo plan — deletes phase2 + phase3)\n'
      printf 'phase3 (redo implement — deletes phase3 only)\n'
      printf 'cancel\n'
  } | qqq_fzf --prompt='rewind to > ' --height=40%) || { printf '[qqq] cancelled.\n'; return 0; }

  local rewind_to
  case "$phase_pick" in
    phase1*) rewind_to=1 ;;
    phase2*) rewind_to=2 ;;
    phase3*) rewind_to=3 ;;
    *)       printf '[qqq] cancelled.\n'; return 0 ;;
  esac

  local targets=()
  if (( rewind_to <= 1 )); then
    targets+=(phase1-spec.md phase1-ui-outline.md phase1-ui-outline.html phase1-nltp.md)
    local f
    for f in "$sess"/phase1-nltp-review-*.md; do
      [[ -f "$f" ]] && targets+=("$(basename "$f")")
    done
  fi
  if (( rewind_to <= 2 )); then
    targets+=(phase1-tech-spec.md)
    targets+=(phase2-code-plan.md phase2-review-log.md)
    targets+=(phase2-review-state.json)
    local f
    for f in "$sess"/phase2-review-round-*.md \
             "$sess"/phase2-g1-explorer-*.md \
             "$sess"/phase2-g2-architect-*.md \
             "$sess"/phase2-g3-critic-*.md \
             "$sess"/phase2-codex-review-*.md \
             "$sess"/phase2-claude-review-*.md; do
      [[ -f "$f" ]] && targets+=("$(basename "$f")")
    done
  fi
  if (( rewind_to <= 3 )); then
    targets+=(phase3-implement-log.md)
    local f
    for f in "$sess"/phase3-codex-review-*.md; do
      [[ -f "$f" ]] && targets+=("$(basename "$f")")
    done
  fi

  local existing=()
  local t
  for t in "${targets[@]}"; do
    [[ -f "$sess/$t" ]] && existing+=("$t")
  done

  if (( ${#existing[@]} == 0 )); then
    printf '[qqq] nothing to rewind at phase%d+.\n' "$rewind_to"
    return 0
  fi

  printf '[qqq] rewind to phase%d will delete these files in %s:\n' "$rewind_to" "$(basename "$sess")"
  printf '  - %s\n' "${existing[@]}"
  local confirm
  qqq_read_prompt "[qqq] proceed? type 'yes' to confirm: " confirm || return 1
  if [[ "$confirm" != "yes" ]]; then
    printf '[qqq] cancelled.\n'
    return 0
  fi
  for t in "${existing[@]}"; do
    rm -f "$sess/$t"
  done
  printf '[qqq] removed %d file(s).\n' "${#existing[@]}"
}

view_artifacts() {
  local sess="$1"
  ensure_tmux_session
  if window_exists "menu"; then
    tmux split-window -d -t "$TMUX_SESSION_NAME:menu" -h "cd '$sess' && ls -la && exec $SHELL"
    # Make the split available without stealing focus from the menu pane.
    select_menu_window
    attach_if_outside
  else
    # menu window was closed — fall back to a dedicated window.
    launch_in_tmux_window "$(qqq_window_slug_from_session_dir "$sess"):view-artifacts" "cd '$sess' && ls -la"
  fi
}

open_session_dir() {
  local sess="$1"
  launch_in_tmux_window "$(qqq_window_slug_from_session_dir "$sess"):shell" "cd '$sess' && exec $SHELL"
}

# ---------------------------------------------------------------------------
# Merge-time artifact commit (Stage 4)
# ---------------------------------------------------------------------------

# Commit only the active session artifact tree in the given worktree.
# Excludes .qqq.lock via pathspec. Idempotent — no-op when nothing changed.
# Returns 0 on skip or success; stderr for status lines only.
commit_session_artifacts_if_dirty() {
  local worktree="$1" session_dir="$2"
  [[ -d "$worktree" && -d "$session_dir" ]] || return 0
  local rel="${session_dir#"$worktree"/}"
  # Guard: session_dir must actually be under worktree.
  [[ "$rel" == "$session_dir" ]] && return 0

  # Nothing tracked-changed AND nothing new — skip.
  if git -C "$worktree" diff --quiet HEAD -- "$rel" 2>/dev/null \
     && [[ -z $(git -C "$worktree" ls-files --others --exclude-standard -- "$rel" 2>/dev/null) ]]; then
    return 0
  fi

  git -C "$worktree" add -- "$rel" ":!$rel/.qqq.lock" >/dev/null 2>&1 || true

  # If staging the pathspec yielded nothing (e.g. only .qqq.lock changed), bail.
  if git -C "$worktree" diff --cached --quiet -- "$rel" 2>/dev/null; then
    return 0
  fi

  local slug
  slug=$(qqq_slug_from_session_dir "$session_dir")
  if git -C "$worktree" commit --no-verify -m "qqq: $slug archive session artifacts" >/dev/null; then
    printf '[qqq] auto-committed session artifacts under %s\n' "$rel" >&2
  fi
}

# Rename session dir from <worktree>/<launch-subdir>/claude-works/<date_slug>/ to
# <worktree>/<launch-subdir>/claude-works-completed/<date_slug>/ with a dedicated commit.
# Emits new absolute path on stdout when the move succeeds; empty otherwise.
# Fails fast when the destination already exists.
archive_session_to_completed() {
  local worktree="$1" session_dir="$2"
  [[ -d "$worktree" && -d "$session_dir" ]] || return 0
  local rel_src="${session_dir#"$worktree"/}"
  [[ "$rel_src" == "$session_dir" ]] && return 0  # not inside worktree

  local base slug dest_rel dest_abs rel_parent prefix
  local merge_state_src merge_state_dest merge_state_tmp=""
  local moved_to_dest=no
  base=$(basename "$session_dir")
  slug=$(qqq_slug_from_session_dir "$session_dir")
  rel_parent=$(dirname "$rel_src")
  if [[ "$rel_parent" == "claude-works" ]]; then
    prefix=""
  elif [[ "$rel_parent" == */claude-works ]]; then
    prefix="${rel_parent%/claude-works}"
  else
    printf '[qqq] archive source is not under a claude-works/ tree: %s\n' "$rel_src" >&2
    return 1
  fi
  dest_rel="$(qqq_path_join "$prefix" "claude-works-completed/$base")"
  dest_abs="$worktree/$dest_rel"
  merge_state_src="$session_dir/.qqq/merge-state.json"
  merge_state_dest="$dest_abs/.qqq/merge-state.json"

  # Drop the runtime lock file so the source dir has no untracked leftovers
  # (git mv would otherwise leave .qqq.lock behind in the now-empty source).
  # The lock itself stays held via fd 9 against the inode.
  rm -f "$session_dir/.qqq.lock" 2>/dev/null || true
  if [[ -f "$merge_state_src" ]]; then
    merge_state_tmp=$(mktemp "${TMPDIR:-/tmp}/qqq-merge-state.XXXXXX") || return 1
    if ! mv "$merge_state_src" "$merge_state_tmp" 2>/dev/null; then
      rm -f "$merge_state_tmp" 2>/dev/null || true
      printf '[qqq] failed to preserve merge-state sidecar before archive.\n' >&2
      return 1
    fi
  fi

  mkdir -p "$(dirname "$dest_abs")"

  if [[ -e "$dest_abs" ]]; then
    printf '[qqq] completed archive already exists: %s\n' "$dest_abs" >&2
    printf '[qqq] keep the existing archive, clean it up manually, or change the session slug before retrying.\n' >&2
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      mkdir -p "$(dirname "$merge_state_src")"
      mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
    fi
    return 1
  fi

  if ! git -C "$worktree" mv "$rel_src" "$dest_rel" 2>/dev/null; then
    # Fallback: plain mv + add (source may have had untracked residue).
    if ! mv "$session_dir" "$dest_abs" 2>/dev/null; then
      if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
        mkdir -p "$(dirname "$merge_state_src")"
        mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
      fi
      printf '[qqq] archive mv failed (src=%s, dst=%s)\n' "$session_dir" "$dest_abs" >&2
      return 1
    fi
  fi
  moved_to_dest=yes
  git -C "$worktree" add -A -- "$rel_src" 2>/dev/null || true
  git -C "$worktree" add -- "$dest_rel" 2>/dev/null || true

  if git -C "$worktree" diff --cached --quiet 2>/dev/null; then
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      if [[ -d "$dest_abs" ]]; then
        mkdir -p "$(dirname "$merge_state_dest")"
        mv "$merge_state_tmp" "$merge_state_dest" 2>/dev/null || true
      else
        mkdir -p "$(dirname "$merge_state_src")"
        mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
      fi
    fi
    return 0  # nothing staged — caller treats as no-op, no new path emitted
  fi

  if ! git -C "$worktree" commit --no-verify -m "qqq: $slug archive to completed" >/dev/null; then
    if [[ "$moved_to_dest" == "yes" && -d "$dest_abs" && ! -e "$session_dir" ]]; then
      mkdir -p "$(dirname "$session_dir")"
      mv "$dest_abs" "$session_dir" 2>/dev/null || true
      git -C "$worktree" add -A -- "$rel_src" 2>/dev/null || true
      git -C "$worktree" add -A -- "$dest_rel" 2>/dev/null || true
    fi
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      mkdir -p "$(dirname "$merge_state_src")"
      mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
    fi
    printf '[qqq] archive commit failed.\n' >&2
    return 1
  fi
  if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
    mkdir -p "$(dirname "$merge_state_dest")"
    mv "$merge_state_tmp" "$merge_state_dest" 2>/dev/null || true
  fi
  printf '[qqq] archived session to %s\n' "$dest_rel" >&2
  printf '%s' "$dest_abs"
}

# ---------------------------------------------------------------------------
# Worktree CRUD actions (Stage 2)
# ---------------------------------------------------------------------------

rollback_worktree_create() {
  local leader_repo="$1" wt_path="$2" branch="$3"
  local created_wt="$4" created_branch="$5"
  local moved_from="$6" moved_to="$7"
  # Undo in reverse order: session mv, worktree add, branch create.
  if [[ -n "$moved_to" && -d "$moved_to" ]]; then
    if [[ -n "$moved_from" && ! -d "$moved_from" ]]; then
      mv "$moved_to" "$moved_from" 2>/dev/null || true
    elif [[ -z "$moved_from" ]]; then
      rm -rf "$moved_to" 2>/dev/null || true
    fi
  fi
  if [[ "$created_wt" == "yes" ]]; then
    git -C "$leader_repo" worktree remove --force "$wt_path" 2>/dev/null \
      || { rm -rf "$wt_path" 2>/dev/null; git -C "$leader_repo" worktree prune 2>/dev/null || true; }
  fi
  if [[ "$created_branch" == "yes" ]]; then
    git -C "$leader_repo" branch -D "$branch" 2>/dev/null || true
  fi
}

qqq_bootstrap_session_worktree() {
  local session_name="$1"
  local source_session_dir="${2:-}"
  local leader_repo
  leader_repo=$(qqq_leader_repo_from "${source_session_dir:-$PWD}" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || {
      printf '[qqq] cannot create session: not inside a git repo.\n' >&2
      return 1
    }

  local repo_lock_held=no
  qqq_acquire_repo_lock "$leader_repo" || return 1
  repo_lock_held=yes
  trap 'if [[ "$repo_lock_held" == "yes" ]]; then qqq_release_repo_lock; fi' RETURN

  local works_base
  works_base=$(qqq_session_base_for_checkout "$leader_repo" "$leader_repo")
  if qqq_check_gitignore "$leader_repo" "$works_base" 2>/dev/null; then
    printf '[qqq] `claude-works/` is gitignored in %s.\n' "$leader_repo" >&2
    printf '[qqq] remove it from .gitignore (or a parent .gitignore) so session artifacts can be committed, then re-run.\n' >&2
    return 1
  fi
  if ! qqq_ensure_worktree_bucket_ignored "$leader_repo"; then
    printf '[qqq] failed to register /.qqq-worktrees/ as ignored in %s.\n' "$leader_repo" >&2
    return 1
  fi

  local dev_branch
  dev_branch=$(qqq_origin_dev_branch)
  if [[ "${QQQ_NO_FETCH:-0}" != "1" ]]; then
    if ! git -C "$leader_repo" fetch origin "$dev_branch" 2>/dev/null; then
      printf '[qqq] `git fetch origin %s` failed. Set QQQ_NO_FETCH=1 to skip, or check remote/auth.\n' "$dev_branch" >&2
      return 1
    fi
  fi

  local slug branch wt_path
  slug=$(qqq_slug_from_session_dir "$session_name")
  branch=$(qqq_worktree_branch_for "$slug")
  wt_path=$(qqq_worktree_path_for "$leader_repo" "$slug")

  local reuse=no
  if qqq_branch_exists "$leader_repo" "$branch" any; then
    printf '[qqq] branch %s already exists (local or remote).\n' "$branch" >&2
    local reply
    qqq_read_prompt "[qqq] reuse existing branch? [y/N]: " reply || return 1
    if [[ "$reply" == [Yy]* ]]; then
      reuse=yes
    else
      printf '[qqq] aborted. Pick a different slug or delete the branch first.\n' >&2
      return 1
    fi
  fi

  local created_wt=no created_branch=no moved_from="" moved_to=""
  mkdir -p "$(dirname "$wt_path")"

  if [[ "$reuse" == "yes" ]]; then
    if ! git -C "$leader_repo" worktree add "$wt_path" "$branch" >&2; then
      printf '[qqq] `git worktree add %s %s` failed.\n' "$wt_path" "$branch" >&2
      return 1
    fi
    created_wt=yes
  else
    local base_ref="origin/$dev_branch"
    if ! qqq_branch_exists "$leader_repo" "$dev_branch" remote; then
      printf '[qqq] origin/%s not found. Set QQQ_DEV_BRANCH or push the branch first.\n' "$dev_branch" >&2
      return 1
    fi
    if ! git -C "$leader_repo" worktree add -b "$branch" "$wt_path" "$base_ref" >&2; then
      printf '[qqq] `git worktree add -b %s` failed.\n' "$branch" >&2
      return 1
    fi
    created_wt=yes
    created_branch=yes
  fi

  local new_session_dir
  new_session_dir="$(qqq_session_base_for_checkout "$wt_path" "$leader_repo")/$session_name"
  mkdir -p "$(dirname "$new_session_dir")"
  if [[ -n "$source_session_dir" && -d "$source_session_dir" ]]; then
    moved_from="$source_session_dir"
    moved_to="$new_session_dir"
    if ! mv "$source_session_dir" "$new_session_dir" 2>/dev/null; then
      if cp -a "$source_session_dir/." "$new_session_dir/" 2>/dev/null && rm -rf "$source_session_dir"; then
        :
      else
        printf '[qqq] failed to migrate session dir into worktree. rolling back.\n' >&2
        rollback_worktree_create "$leader_repo" "$wt_path" "$branch" "$created_wt" "$created_branch" "$moved_from" "$moved_to"
        return 1
      fi
    fi
  else
    if ! mkdir -p "$new_session_dir"; then
      printf '[qqq] failed to create session dir %s. rolling back.\n' "$new_session_dir" >&2
      rollback_worktree_create "$leader_repo" "$wt_path" "$branch" "$created_wt" "$created_branch" "" "$new_session_dir"
      return 1
    fi
  fi

  qqq_release_repo_lock
  repo_lock_held=no
  trap - RETURN

  printf '[qqq] worktree ready: %s (branch %s)\n' "$wt_path" "$branch" >&2
  printf '[qqq] session dir ready: %s\n' "$new_session_dir" >&2
  printf '%s' "$new_session_dir"
}

# Emits the new session_dir on stdout; status/info goes to stderr.
action_worktree_create() {
  local session_dir="$1"
  qqq_log_workflow_event "worktree_create" "started" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "source_session_dir" "$session_dir"
  local new_session_dir
  new_session_dir=$(qqq_bootstrap_session_worktree "$(basename "$session_dir")" "$session_dir") || {
    qqq_log_workflow_event "worktree_create" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION"
    return 1
  }
  qqq_log_workflow_event "worktree_create" "completed" "" "$new_session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION"
  printf '%s' "$new_session_dir"
}

action_worktree_open() {
  local session_dir="$1"
  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || { printf '[qqq] not in a git repo.\n' >&2; return 1; }

  local status_line wt_path wt_state
  status_line=$(qqq_session_worktree_status "$session_dir" "$leader_repo")
  wt_path="${status_line%$'\t'*}"
  wt_state="${status_line##*$'\t'}"

  case "$wt_state" in
    live) : ;;
    ghost)
      printf '[qqq] worktree path missing (ghost: %s). prune now? [Y/n]: ' "$wt_path"
      local reply; read -r reply </dev/tty
      if [[ -z "$reply" || "$reply" == [Yy]* ]]; then
        git -C "$leader_repo" worktree prune
        printf '[qqq] pruned stale worktree metadata.\n'
      fi
      return 0
      ;;
    branch-only|none)
      printf '[qqq] no live linked worktree is available for this session.\n' >&2
      return 1
      ;;
    no-repo)
      printf '[qqq] not in a git repo.\n' >&2
      return 1
      ;;
  esac

  local slug
  slug=$(qqq_window_slug_from_session_dir "$session_dir")
  local win_name="${slug}:shell"
  local cmd worktree_cwd
  worktree_cwd=$(qqq_checkout_exec_cwd "$wt_path" "$leader_repo")
  printf -v cmd "cd %q && export QQQ_SESSION_DIR=%q QQQ_LEADER_CWD=%q && exec %s" \
    "$worktree_cwd" "$session_dir" "$(qqq_launch_cwd)" "$SHELL"
  launch_in_tmux_window "$win_name" "$cmd"
}

action_resolve_rebase_conflict() {
  local session_dir="$1"
  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || { printf '[qqq] not in a git repo.\n' >&2; return 1; }

  local status_line wt_path wt_state dev_branch
  status_line=$(qqq_session_worktree_status "$session_dir" "$leader_repo")
  wt_path="${status_line%$'\t'*}"
  wt_state="${status_line##*$'\t'}"
  dev_branch=$(qqq_origin_dev_branch)

  if [[ "$wt_state" != "live" ]]; then
    printf '[qqq] cannot resolve conflicts: worktree state is %s.\n' "$wt_state" >&2
    return 1
  fi
  if ! qqq_worktree_rebase_in_progress "$wt_path"; then
    printf '[qqq] no rebase is in progress in %s.\n' "$wt_path" >&2
    return 1
  fi

  launch_rebase_conflict_resolver "$session_dir" "$wt_path" "$dev_branch"
}

qqq_branch_checked_out_elsewhere() {
  local repo_root="$1" branch="$2" exclude_path="${3:-}"
  local path entry_branch phys
  while IFS=$'\t' read -r path entry_branch phys; do
    [[ "$entry_branch" == "$branch" ]] || continue
    [[ "$phys" == "yes" ]] || continue
    [[ -n "$exclude_path" && "$path" == "$exclude_path" ]] && continue
    return 0
  done < <(qqq_list_worktrees "$repo_root")
  return 1
}

action_worktree_remove() {
  local session_dir="$1"
  local cleanup_mode="${2:-selective}"
  qqq_log_workflow_event "worktree_remove" "started" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "cleanup_mode" "$cleanup_mode"
  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || {
      printf '[qqq] not in a git repo.\n' >&2
      qqq_log_workflow_event "worktree_remove" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "not in a git repo"
      return 1
    }

  qqq_acquire_repo_lock "$leader_repo" || {
    qqq_log_workflow_event "worktree_remove" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "repo lock busy"
    return 1
  }

  local status_line wt_path wt_state slug branch merge_status
  status_line=$(qqq_session_worktree_status "$session_dir" "$leader_repo")
  wt_path="${status_line%$'\t'*}"
  wt_state="${status_line##*$'\t'}"
  slug=$(qqq_slug_from_session_dir "$session_dir")
  branch=$(qqq_worktree_branch_for "$slug")
  merge_status=$(qqq_session_merge_display_status "$session_dir")

  if [[ "$wt_state" == "ghost" ]]; then
    git -C "$leader_repo" worktree prune
    wt_state="branch-only"
    wt_path=""
  fi

  local do_wt=no do_local=no do_remote=no reply
  local local_exists=no remote_exists=no local_delete_safe=yes rc=0
  qqq_branch_exists "$leader_repo" "$branch" local && local_exists=yes
  qqq_branch_exists "$leader_repo" "$branch" remote && remote_exists=yes
  if [[ "$local_exists" == "yes" ]] && qqq_branch_checked_out_elsewhere "$leader_repo" "$branch" "$wt_path"; then
    local_delete_safe=no
  fi

  printf '[qqq] preflight:\n' >&2
  printf '  - worktree state: %s\n' "$wt_state" >&2
  if [[ -n "$wt_path" ]]; then
    printf '  - worktree path: %s\n' "$wt_path" >&2
  fi
  printf '  - local branch %s: %s\n' "$branch" "$local_exists" >&2
  if [[ "$local_exists" == "yes" ]]; then
    if [[ "$local_delete_safe" == "yes" ]]; then
      printf '  - local branch delete precheck: ready\n' >&2
    else
      printf '  - local branch delete precheck: blocked (branch checked out in another worktree)\n' >&2
    fi
  fi
  printf '  - remote branch origin/%s: %s\n' "$branch" "$remote_exists" >&2
  if [[ "$remote_exists" == "yes" ]]; then
    printf '  - remote delete precheck: best-effort only (branch protections may still reject)\n' >&2
  fi
  if qqq_merge_status_requires_recovery_warning "$merge_status"; then
    printf '[qqq] warning: this session is [%s]. Removing the worktree or branch can discard merge recovery state.\n' \
      "${merge_status//_/-}" >&2
    qqq_read_prompt "[qqq] continue with worktree-remove anyway? [y/N]: " reply || {
      qqq_release_repo_lock
      return 1
    }
    if [[ "$reply" != [Yy]* ]]; then
      printf '[qqq] cleanup aborted.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "worktree_remove" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "cleanup declined for recoverable merge session" \
        "branch" "$branch"
      return 1
    fi
  fi

  if [[ "$cleanup_mode" == "all" ]]; then
    [[ "$wt_state" == "live" ]] && do_wt=yes
    [[ "$local_exists" == "yes" ]] && do_local=yes
    [[ "$remote_exists" == "yes" ]] && do_remote=yes
    if [[ "$do_local" == "yes" && "$local_delete_safe" != "yes" ]]; then
      printf '[qqq] cleanup aborted before changes: local branch %s is checked out in another worktree.\n' "$branch" >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "worktree_remove" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "local branch checked out elsewhere" \
        "branch" "$branch"
      return 1
    fi
  else
    if [[ "$wt_state" == "live" ]]; then
      qqq_read_prompt "[qqq] remove worktree $wt_path ? [y/N]: " reply || {
        qqq_release_repo_lock
        return 1
      }
      [[ "$reply" == [Yy]* ]] && do_wt=yes
    fi
    if [[ "$local_exists" == "yes" ]]; then
      if [[ "$local_delete_safe" == "yes" ]]; then
        qqq_read_prompt "[qqq] delete local branch $branch ? [y/N]: " reply || {
          qqq_release_repo_lock
          return 1
        }
        [[ "$reply" == [Yy]* ]] && do_local=yes
      else
        printf '[qqq] skip local branch delete: %s is checked out in another worktree.\n' "$branch" >&2
      fi
    fi
    if [[ "$remote_exists" == "yes" ]]; then
      qqq_read_prompt "[qqq] delete remote branch origin/$branch ? [y/N]: " reply || {
        qqq_release_repo_lock
        return 1
      }
      [[ "$reply" == [Yy]* ]] && do_remote=yes
    fi
  fi

  if [[ "$do_wt" == "yes" && -n "$wt_path" ]]; then
    if git -C "$leader_repo" worktree remove --force "$wt_path" 2>/dev/null; then
      printf '[qqq] removed worktree %s\n' "$wt_path"
    else
      if rm -rf "$wt_path" && git -C "$leader_repo" worktree prune 2>/dev/null; then
        printf '[qqq] force-removed worktree %s\n' "$wt_path"
      else
        printf '[qqq] failed to remove worktree %s\n' "$wt_path" >&2
        rc=1
      fi
    fi
  fi
  if (( rc == 0 )) && [[ "$do_local" == "yes" ]]; then
    if git -C "$leader_repo" branch -D "$branch" 2>/dev/null; then
      printf '[qqq] deleted local branch %s\n' "$branch"
    else
      printf '[qqq] could not delete local branch %s (still checked out somewhere?)\n' "$branch" >&2
      rc=1
    fi
  fi
  if (( rc == 0 )) && [[ "$do_remote" == "yes" ]]; then
    if git -C "$leader_repo" push origin --delete "$branch" 2>/dev/null; then
      printf '[qqq] deleted remote branch %s\n' "$branch"
    else
      local url
      url=$(git -C "$leader_repo" config --get remote.origin.url 2>/dev/null)
      printf '[qqq] could not delete remote branch (protected?). Delete via GitLab UI: %s/-/branches\n' "$url" >&2
      rc=1
    fi
  fi

  qqq_release_repo_lock
  if (( rc == 0 )); then
    qqq_log_workflow_event "worktree_remove" "completed" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "cleanup_mode" "$cleanup_mode" \
      "branch" "$branch"
  else
    qqq_log_workflow_event "worktree_remove" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "cleanup_mode" "$cleanup_mode" \
      "reason" "cleanup incomplete" \
      "branch" "$branch"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Merge protocol (Stage 3)
# ---------------------------------------------------------------------------

_merge_cleanup_prompt() {
  local session_dir="$1"
  local merge_status
  merge_status=$(qqq_session_merge_display_status "$session_dir")
  if [[ "$merge_status" == "push_pending" ]]; then
    printf '[qqq] cleanup skipped: session is still [push-pending]. Resume or inspect it first.\n'
    return 0
  fi
  local reply
  qqq_read_prompt "[qqq] cleanup all (worktree + local branch + remote branch)? [Y/n/selective]: " reply || return 1
  case "${reply:-Y}" in
    Y|y|"")
      action_worktree_remove "$session_dir" all
      ;;
    s|S|selective)
      action_worktree_remove "$session_dir" selective
      ;;
    n|N)
      printf '[qqq] cleanup skipped. Run worktree-remove later if needed.\n'
      ;;
    *)
      printf '[qqq] unrecognized input — skipping cleanup.\n'
      ;;
  esac
}

action_worktree_merge() {
  local session_dir="$1"
  local resume_push_only="${2:-0}"
  local merge_event="worktree_merge"
  local canonical_session="$session_dir"
  if [[ "$resume_push_only" == "1" ]]; then
    merge_event="merge_resume_push"
  fi
  qqq_log_workflow_event "$merge_event" "started" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION"

  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || {
      printf '[qqq] not in a git repo.\n' >&2
      qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "not in a git repo"
      printf '%s' "$canonical_session"
      return 1
    }

  qqq_acquire_repo_lock "$leader_repo" || {
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "repo lock busy"
    printf '%s' "$canonical_session"
    return 1
  }

  local status_line wt_path wt_state slug branch dev_branch
  local session_basename archived_session_dir premerge_tag state_path
  local expected_dev_head="" merge_commit_head="" leader_archived_base="" saved_leader_archived_session_dir=""
  status_line=$(qqq_session_worktree_status "$session_dir" "$leader_repo")
  wt_path="${status_line%$'\t'*}"
  wt_state="${status_line##*$'\t'}"
  slug=$(qqq_slug_from_session_dir "$session_dir")
  branch=$(qqq_worktree_branch_for "$slug")
  dev_branch=$(qqq_origin_dev_branch)
  session_basename=$(basename "$session_dir")
  premerge_tag="qqq-premerge/$slug"
  state_path=$(qqq_merge_state_path "$session_dir")
  leader_archived_base="$(qqq_completed_base_for_checkout "$leader_repo" "$leader_repo")/$session_basename"

  # --- resume-push-only fast path: retry push, keep local merge intact ---
  if [[ "$resume_push_only" == "1" ]]; then
    local saved_status saved_branch saved_dev_branch saved_leader_repo saved_worktree_path
    local saved_archived_session_dir saved_premerge_tag saved_expected_dev_head saved_merge_commit_head
    local current_dev_head push_log push_rc
    if [[ ! -f "$state_path" ]]; then
      printf '[qqq] --merge-resume-push requires %s\n' "$state_path" >&2
      printf '[qqq] no saved merge recovery state was found for this session.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "merge state missing"
      printf '%s' "$canonical_session"
      return 1
    fi
    saved_status=$(qqq_merge_state_get "$session_dir" status 2>/dev/null || printf '')
    saved_branch=$(qqq_merge_state_get "$session_dir" branch 2>/dev/null || printf '')
    saved_dev_branch=$(qqq_merge_state_get "$session_dir" dev_branch 2>/dev/null || printf '')
    saved_leader_repo=$(qqq_merge_state_get "$session_dir" leader_repo 2>/dev/null || printf '')
    saved_worktree_path=$(qqq_merge_state_get "$session_dir" worktree_path 2>/dev/null || printf '')
    saved_archived_session_dir=$(qqq_merge_state_get "$session_dir" archived_session_dir 2>/dev/null || printf '')
    saved_premerge_tag=$(qqq_merge_state_get "$session_dir" premerge_tag 2>/dev/null || printf '')
    saved_expected_dev_head=$(qqq_merge_state_get "$session_dir" expected_dev_head 2>/dev/null || printf '')
    saved_merge_commit_head=$(qqq_merge_state_get "$session_dir" merge_commit_head 2>/dev/null || printf '')
    saved_leader_archived_session_dir=$(qqq_merge_state_get "$session_dir" leader_archived_session_dir 2>/dev/null || printf '')

    if [[ -n "$saved_archived_session_dir" ]]; then
      canonical_session="$saved_archived_session_dir"
    fi
    if [[ "$saved_status" != "push_pending" ]]; then
      printf '[qqq] --merge-resume-push is only allowed for sessions with status=push_pending.\n' >&2
      printf '[qqq] current saved status: %s\n' "${saved_status:-<missing>}" >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "merge state is not push_pending" \
        "saved_status" "${saved_status:-missing}"
      printf '%s' "$canonical_session"
      return 1
    fi
    if [[ -z "$saved_branch" || -z "$saved_dev_branch" || -z "$saved_leader_repo" || -z "$saved_merge_commit_head" ]]; then
      printf '[qqq] saved merge state is incomplete. Missing branch/dev/leader/head fields.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "merge state incomplete"
      printf '%s' "$canonical_session"
      return 1
    fi
    if [[ "$saved_leader_repo" != "$leader_repo" ]]; then
      printf '[qqq] saved merge state points to a different leader repo:\n' >&2
      printf '  saved: %s\n  current: %s\n' "$saved_leader_repo" "$leader_repo" >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "leader repo mismatch in merge state"
      printf '%s' "$canonical_session"
      return 1
    fi

    branch="$saved_branch"
    dev_branch="$saved_dev_branch"
    wt_path="$saved_worktree_path"
    archived_session_dir="${saved_archived_session_dir:-$canonical_session}"
    premerge_tag="${saved_premerge_tag:-$premerge_tag}"
    expected_dev_head="$saved_expected_dev_head"
    merge_commit_head="$saved_merge_commit_head"
    if [[ -n "$saved_leader_archived_session_dir" ]]; then
      leader_archived_base="$saved_leader_archived_session_dir"
    fi

    current_dev_head=$(git -C "$leader_repo" rev-parse "$dev_branch" 2>/dev/null || printf '')
    if [[ -z "$current_dev_head" ]]; then
      printf '[qqq] local %s does not exist in %s.\n' "$dev_branch" "$leader_repo" >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "local dev branch missing during resume" \
        "dev_branch" "$dev_branch"
      printf '%s' "$canonical_session"
      return 1
    fi
    if [[ "$current_dev_head" != "$merge_commit_head" ]]; then
      printf '[qqq] refusing resume: local %s HEAD changed since the saved merge.\n' "$dev_branch" >&2
      printf '  saved merge HEAD: %s\n' "$merge_commit_head" >&2
      printf '  current HEAD:     %s\n' "$current_dev_head" >&2
      printf '[qqq] inspect the branch, reset it to the saved merge commit if appropriate, or re-run the merge from the archived session.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "local dev head mismatch during resume" \
        "dev_branch" "$dev_branch"
      printf '%s' "$canonical_session"
      return 1
    fi

    printf '[qqq] --merge-resume-push: retrying `push origin %s`\n' "$dev_branch" >&2
    push_log=$(git -C "$leader_repo" push origin "$dev_branch" 2>&1)
    push_rc=$?
    printf '%s\n' "$push_log" >&2
    if (( push_rc == 0 )); then
      printf '[qqq] push succeeded.\n' >&2
      qqq_merge_state_write "${archived_session_dir:-$canonical_session}" completed \
        "$session_basename" "$branch" "$dev_branch" "$leader_repo" "$wt_path" \
        "$archived_session_dir" "$premerge_tag" "$expected_dev_head" "$merge_commit_head" \
        "$leader_archived_base" || true
      git -C "$leader_repo" tag -d "$premerge_tag" >/dev/null 2>&1 || true
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "completed" "" "${archived_session_dir:-$canonical_session}" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "dev_branch" "$dev_branch"
      _merge_cleanup_prompt "${archived_session_dir:-$canonical_session}" >&2
      canonical_session="${archived_session_dir:-$canonical_session}"
      printf '%s' "$canonical_session"
      return 0
    fi
    printf '[qqq] push still failing. Backup tag preserved: %s\n' "$premerge_tag" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "${archived_session_dir:-$canonical_session}" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "resume push failed" \
      "dev_branch" "$dev_branch"
    printf '%s' "${archived_session_dir:-$canonical_session}"
    return 1
  fi

  # --- preflight ---
  if [[ "$wt_state" != "live" ]]; then
    printf '[qqq] cannot merge: worktree state is %s. A live linked worktree is required.\n' "$wt_state" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "worktree not live" \
      "worktree_state" "$wt_state"
    printf '%s' "$canonical_session"
    return 1
  fi
  if [[ -n $(git -C "$leader_repo" status --porcelain 2>/dev/null) ]]; then
    printf '[qqq] leader repo is dirty — commit or stash in leader first.\n' >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "leader repo dirty"
    printf '%s' "$canonical_session"
    return 1
  fi
  if qqq_worktree_rebase_in_progress "$wt_path"; then
    printf '[qqq] worktree has an in-progress rebase. Finish or abort it first.\n' >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "rebase already in progress"
    printf '%s' "$canonical_session"
    return 1
  fi

  # auto-commit artifacts, then check for leftover code changes.
  commit_session_artifacts_if_dirty "$wt_path" "$session_dir"
  local wt_dirty
  wt_dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null)
  if [[ -n "$wt_dirty" ]]; then
    printf '[qqq] worktree still has uncommitted changes:\n' >&2
    printf '  code files (you must commit manually):\n' >&2
    printf '%s\n' "$wt_dirty" | sed 's/^/    /' >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "worktree dirty after artifact commit"
    printf '%s' "$canonical_session"
    return 1
  fi

  if [[ "${QQQ_NO_FETCH:-0}" != "1" ]]; then
    if ! git -C "$leader_repo" fetch origin "$dev_branch" 2>/dev/null; then
      printf '[qqq] fetch origin/%s failed. Set QQQ_NO_FETCH=1 to skip, or check remote/auth.\n' "$dev_branch" >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "fetch failed" \
        "dev_branch" "$dev_branch"
      printf '%s' "$canonical_session"
      return 1
    fi
  fi

  # unpushed merges on local dev block new merges (would compound push failures).
  if qqq_branch_exists "$leader_repo" "$dev_branch" local; then
    local ahead
    ahead=$(git -C "$leader_repo" rev-list --count "origin/$dev_branch..$dev_branch" 2>/dev/null || echo 0)
    if (( ahead > 0 )); then
      printf '[qqq] local %s is %d commit(s) ahead of origin/%s. Push those first (qqq --merge-resume-push) before merging %s.\n' \
        "$dev_branch" "$ahead" "$dev_branch" "$branch" >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "local dev ahead of origin" \
        "dev_branch" "$dev_branch"
      printf '%s' "$canonical_session"
      return 1
    fi
  fi

  # already-merged? short-circuit to cleanup.
  if git -C "$leader_repo" merge-base --is-ancestor "$branch" "origin/$dev_branch" 2>/dev/null; then
    printf '[qqq] %s already merged into origin/%s — nothing to rebase/merge.\n' "$branch" "$dev_branch" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "completed" "" "$canonical_session" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "result_reason" "already merged" \
      "branch" "$branch" \
      "dev_branch" "$dev_branch"
    _merge_cleanup_prompt "$canonical_session" >&2
    printf '%s' "$canonical_session"
    return 0
  fi

  # backup tag so the user can recover the pre-rebase state of qqq/<slug>.
  git -C "$leader_repo" tag -f "$premerge_tag" "$branch" >/dev/null 2>&1

  # --- rebase inside the worktree ---
  printf '[qqq] rebasing %s onto origin/%s...\n' "$branch" "$dev_branch" >&2
  if ! git -C "$wt_path" rebase "origin/$dev_branch" >&2; then
    printf '[qqq] rebase hit conflicts in %s.\n' "$wt_path" >&2
    local reply
    qqq_read_prompt "[qqq] launch Codex conflict resolver now? [y/N]: " reply || {
      qqq_release_repo_lock
      return 1
    }
    if [[ "$reply" == [Yy]* ]]; then
      printf '[qqq] leaving the rebase in progress for Codex-assisted resolution.\n' >&2
      printf '[qqq] after the resolver finishes, re-run worktree-merge.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "rebase conflict requires resolver" \
        "branch" "$branch"
      launch_rebase_conflict_resolver "$session_dir" "$wt_path" "$dev_branch"
      printf '%s' "$canonical_session"
      return 1
    fi
    printf '[qqq] aborting rebase so dev stays untouched.\n' >&2
    git -C "$wt_path" rebase --abort 2>/dev/null || true
    printf '[qqq] resolve manually in %s (git rebase origin/%s), then re-run worktree-merge.\n' "$wt_path" "$dev_branch" >&2
    printf '[qqq] backup: %s (git reset --hard %s to recover)\n' "$premerge_tag" "$premerge_tag" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "rebase conflict aborted" \
      "branch" "$branch"
    printf '%s' "$canonical_session"
    return 1
  fi

  # rebase verification: `rev-list` ahead count must equal `cherry` unique-count.
  local ahead_after cherry_plus
  ahead_after=$(git -C "$wt_path" rev-list --count "origin/$dev_branch..$branch" 2>/dev/null || echo 0)
  cherry_plus=$(git -C "$wt_path" cherry "origin/$dev_branch" "$branch" 2>/dev/null | grep -c '^+' || true)
  if [[ "$ahead_after" != "$cherry_plus" ]]; then
    printf '[qqq] rebase verification mismatch (ahead=%s, cherry+=%s). Possible `rebase --skip` mishap.\n' \
      "$ahead_after" "$cherry_plus" >&2
    printf '[qqq] backup: %s. Inspect and recover manually.\n' "$premerge_tag" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "rebase verification mismatch" \
      "branch" "$branch"
    printf '%s' "$canonical_session"
    return 1
  fi

  qqq_merge_state_write "$session_dir" rebased \
    "$session_basename" "$branch" "$dev_branch" "$leader_repo" "$wt_path" \
    "" "$premerge_tag" "" "" "$leader_archived_base" || {
      printf '[qqq] failed to persist merge recovery state after rebase.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "failed to write rebased merge state" \
        "branch" "$branch"
      printf '%s' "$canonical_session"
      return 1
    }

  # Archive after the branch has been successfully rebased, so conflict
  # recovery continues to use the stable claude-works/<session>/ path.
  local archived_abs
  archived_abs=$(archive_session_to_completed "$wt_path" "$session_dir") || {
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "archive to completed failed" \
      "branch" "$branch"
    printf '%s' "$canonical_session"
    return 1
  }
  if [[ -n "$archived_abs" ]]; then
    session_dir="$archived_abs"
    canonical_session="$archived_abs"
  fi
  archived_session_dir="$canonical_session"
  qqq_merge_state_write "$canonical_session" archived \
    "$session_basename" "$branch" "$dev_branch" "$leader_repo" "$wt_path" \
    "$archived_session_dir" "$premerge_tag" "" "" "$leader_archived_base" || {
      printf '[qqq] failed to persist archived merge state.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "failed to write archived merge state" \
        "branch" "$branch"
      printf '%s' "$canonical_session"
      return 1
    }

  # --- merge on leader ---
  printf '[qqq] merging %s into %s on leader...\n' "$branch" "$dev_branch" >&2
  if ! qqq_branch_exists "$leader_repo" "$dev_branch" local; then
    git -C "$leader_repo" branch "$dev_branch" "origin/$dev_branch" >/dev/null 2>&1 \
      || {
        printf '[qqq] failed to create local %s.\n' "$dev_branch" >&2
        qqq_release_repo_lock
        qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
          "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
          "reason" "failed to create local dev branch" \
          "dev_branch" "$dev_branch"
        printf '%s' "$canonical_session"
        return 1
      }
  fi
  if ! git -C "$leader_repo" checkout "$dev_branch" >&2; then
    printf '[qqq] checkout %s failed in leader.\n' "$dev_branch" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "checkout dev branch failed" \
      "dev_branch" "$dev_branch"
    printf '%s' "$canonical_session"
    return 1
  fi
  if ! git -C "$leader_repo" pull --ff-only origin "$dev_branch" >&2; then
    printf '[qqq] `git pull --ff-only` failed; local %s diverged.\n' "$dev_branch" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "pull --ff-only failed" \
      "dev_branch" "$dev_branch"
    printf '%s' "$canonical_session"
    return 1
  fi
  expected_dev_head=$(git -C "$leader_repo" rev-parse "$dev_branch" 2>/dev/null || printf '')
  if ! git -C "$leader_repo" merge --no-ff --no-edit -m "Merge $branch into $dev_branch" "$branch" >&2; then
    printf '[qqq] merge failed (unexpected after successful rebase). Resolve in leader then retry.\n' >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "leader merge failed" \
      "branch" "$branch" \
      "dev_branch" "$dev_branch"
    printf '%s' "$canonical_session"
    return 1
  fi
  merge_commit_head=$(git -C "$leader_repo" rev-parse HEAD 2>/dev/null || printf '')
  qqq_merge_state_write "$canonical_session" merged_local \
    "$session_basename" "$branch" "$dev_branch" "$leader_repo" "$wt_path" \
    "$archived_session_dir" "$premerge_tag" "$expected_dev_head" "$merge_commit_head" \
    "$leader_archived_base" || {
      printf '[qqq] failed to persist local merge state.\n' >&2
      qqq_release_repo_lock
      qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "reason" "failed to write merged_local state" \
        "branch" "$branch" \
        "dev_branch" "$dev_branch"
      printf '%s' "$canonical_session"
      return 1
    }

  # --- push ---
  printf '[qqq] pushing origin %s...\n' "$dev_branch" >&2
  local push_log push_rc
  push_log=$(git -C "$leader_repo" push origin "$dev_branch" 2>&1)
  push_rc=$?
  printf '%s\n' "$push_log" >&2
  if (( push_rc != 0 )); then
    qqq_merge_state_write "$canonical_session" push_pending \
      "$session_basename" "$branch" "$dev_branch" "$leader_repo" "$wt_path" \
      "$archived_session_dir" "$premerge_tag" "$expected_dev_head" "$merge_commit_head" \
      "$leader_archived_base" || true
    if grep -qE 'non-fast-forward|fetch first' <<<"$push_log"; then
      printf '[qqq] push rejected (non-fast-forward). Someone pushed %s mid-merge. Local merge kept — run `qqq --merge-resume-push` after pulling.\n' "$dev_branch" >&2
    elif grep -qE 'protected|pre-receive hook declined|protected branch' <<<"$push_log"; then
      printf '[qqq] push rejected (protected branch). Adjust protection or merge via GitLab UI.\n' >&2
    elif grep -qiE 'authentication|could not read|permission' <<<"$push_log"; then
      printf '[qqq] push rejected (auth). Run `glab auth login` or check credentials.\n' >&2
    else
      printf '[qqq] push failed. Local merge kept; retry with `qqq --merge-resume-push`.\n' >&2
    fi
    printf '[qqq] backup tag preserved: %s\n' "$premerge_tag" >&2
    qqq_release_repo_lock
    qqq_log_workflow_event "$merge_event" "error" "" "$canonical_session" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "reason" "push failed" \
      "branch" "$branch" \
      "dev_branch" "$dev_branch"
    printf '%s' "$canonical_session"
    return 1
  fi

  # --- success ---
  qqq_merge_state_write "$canonical_session" completed \
    "$session_basename" "$branch" "$dev_branch" "$leader_repo" "$wt_path" \
    "$archived_session_dir" "$premerge_tag" "$expected_dev_head" "$merge_commit_head" \
    "$leader_archived_base" || true
  git -C "$leader_repo" tag -d "$premerge_tag" >/dev/null 2>&1 || true
  printf '[qqq] merge + push complete.\n' >&2
  qqq_release_repo_lock
  qqq_log_workflow_event "$merge_event" "completed" "" "$canonical_session" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "branch" "$branch" \
    "dev_branch" "$dev_branch"
  _merge_cleanup_prompt "$canonical_session" >&2
  printf '%s' "$canonical_session"
}

# ---------------------------------------------------------------------------
# GitLab MR (Stage 5)
# ---------------------------------------------------------------------------

action_dev_mr_create() {
  local session_dir="$1"

  if ! command -v glab >/dev/null 2>&1; then
    printf '[qqq] glab is not installed — cannot create MR.\n' >&2
    return 1
  fi

  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || { printf '[qqq] not in a git repo.\n' >&2; return 1; }

  # --- preflight ---
  local status_line ready target_branch dev_branch ahead_count local_sync template_count
  local glab_installed glab_auth reason
  status_line=$(qqq_repo_dev_main_mr_status "$leader_repo")
  ready=$(qqq_tsv_field "$status_line" 1)
  target_branch=$(qqq_tsv_field "$status_line" 2)
  dev_branch=$(qqq_tsv_field "$status_line" 3)
  ahead_count=$(qqq_tsv_field "$status_line" 4)
  local_sync=$(qqq_tsv_field "$status_line" 5)
  template_count=$(qqq_tsv_field "$status_line" 6)
  glab_installed=$(qqq_tsv_field "$status_line" 7)
  glab_auth=$(qqq_tsv_field "$status_line" 8)
  reason=$(qqq_tsv_field "$status_line" 9)

  if [[ "$reason" == "origin-main-missing" ]]; then
    printf '[qqq] origin/main does not exist.\n' >&2
    return 1
  fi
  if [[ "${QQQ_NO_FETCH:-0}" != "1" ]]; then
    git -C "$leader_repo" fetch origin "$target_branch" "$dev_branch" 2>/dev/null \
      || printf '[qqq] warning: fetch failed; proceeding with cached refs.\n' >&2
  fi
  status_line=$(qqq_repo_dev_main_mr_status "$leader_repo")
  ready=$(qqq_tsv_field "$status_line" 1)
  ahead_count=$(qqq_tsv_field "$status_line" 4)
  local_sync=$(qqq_tsv_field "$status_line" 5)
  reason=$(qqq_tsv_field "$status_line" 9)

  case "$reason" in
    nothing-to-mr)
      printf '[qqq] origin/%s has no commits beyond origin/%s — nothing to MR.\n' "$dev_branch" "$target_branch"
      return 0
      ;;
    origin-main-missing)
      printf '[qqq] origin/main does not exist.\n' >&2
      return 1
      ;;
    origin-dev-missing)
      printf '[qqq] origin/%s does not exist.\n' "$dev_branch" >&2
      return 1
      ;;
    glab-missing)
      printf '[qqq] glab is not installed — cannot create MR.\n' >&2
      return 1
      ;;
    local-dev-not-synced)
      printf '[qqq] local %s is %s relative to origin/%s.\n' "$dev_branch" "$local_sync" "$dev_branch" >&2
      printf '[qqq] origin/%s is the source of truth for this action. Sync local %s before creating the MR.\n' "$dev_branch" "$dev_branch" >&2
      return 1
      ;;
  esac

  printf '[qqq] creating MR from origin/%s to origin/%s (%s commit(s) ahead).\n' \
    "$dev_branch" "$target_branch" "$ahead_count"
  printf '[qqq] commits on origin/%s not in origin/%s:\n' "$dev_branch" "$target_branch"
  git -C "$leader_repo" log --pretty='  %h %s' "origin/${target_branch}..origin/${dev_branch}" 2>/dev/null | head -20

  # --- template detection ---
  local tmpl_dir="$leader_repo/.gitlab/merge_request_templates"
  local templates=() f
  if [[ -d "$tmpl_dir" ]]; then
    while IFS= read -r -d '' f; do
      templates+=("$(basename "${f%.md}")")
    done < <(find "$tmpl_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
  fi

  local use_project_template=""
  if (( ${#templates[@]} == 1 )); then
    use_project_template="${templates[0]}"
    printf '[qqq] using project template: %s.md\n' "$use_project_template"
  elif (( ${#templates[@]} > 1 )); then
    local picked
    picked=$(printf '%s\n' "${templates[@]}" | qqq_fzf --prompt='MR template > ' --height=30%) || picked=""
    if [[ -n "$picked" ]]; then
      use_project_template="$picked"
      printf '[qqq] using project template: %s.md\n' "$picked"
    fi
  fi

  # Fallback: inline qqq template injected via --description.
  local inline_body=""
  if [[ -z "$use_project_template" ]]; then
    local plugin_tmpl="$HOME/.claude/plugins/local/hskim-plugins/plugins/qqq/templates/gitlab-mr-default.md"
    if [[ -f "$plugin_tmpl" ]]; then
      inline_body=$(cat "$plugin_tmpl")
      printf '[qqq] no project template — using qqq inline template (no project file written).\n'
    else
      printf '[qqq] warning: qqq inline template not found at %s — empty description.\n' "$plugin_tmpl" >&2
    fi
  fi

  # --- title prompt ---
  local title
  qqq_read_prompt "[qqq] MR title: " title || return 1
  if [[ -z "$title" ]]; then
    printf '[qqq] empty title — aborting.\n' >&2
    return 1
  fi

  local -a glab_args=(
    mr create
    --source-branch "$dev_branch"
    --target-branch "$target_branch"
    --title "$title"
  )
  if [[ -n "$use_project_template" ]]; then
    glab_args+=(--template "$use_project_template")
  elif [[ -n "$inline_body" ]]; then
    glab_args+=(--description "$inline_body")
  fi

  printf '[qqq] local %s is synced with origin/%s; proceeding with glab MR creation.\n' "$dev_branch" "$dev_branch"
  printf '[qqq] creating MR via glab...\n'
  ( cd "$leader_repo" && glab "${glab_args[@]}" )
  local rc=$?

  if (( rc != 0 )); then
    printf '[qqq] glab mr create failed (rc=%d). Check `glab auth status` and remote config.\n' "$rc" >&2
    return "$rc"
  fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

usage() {
  sed -n '2,19p' "$0"
}

main() {
  local forced_session="" resume_push=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --session) forced_session="${2:?--session requires a path}"; shift 2 ;;
      --merge-resume-push) resume_push=1; shift ;;
      *) printf 'qqq: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  check_deps
  if ! qqq_is_in_git_repo "$PWD"; then
    printf '[qqq] must be run from inside a git repository: %s\n' "$PWD" >&2
    exit 1
  fi
  # Per-repo tmux isolation: each repo gets its own "qqq|<repo-slug>" session.
  TMUX_SESSION_NAME="qqq|$(qqq_repo_slug_from "$PWD")"
  # Remember the cwd where qqq was launched so agent windows start there
  # (not in claude-works/<session>/). Exported for subshells / fzf preview.
  QQQ_LAUNCH_PWD="$PWD"
  export QQQ_LAUNCH_PWD
  check_nested_tmux
  ensure_works_dir
  ensure_tmux_session

  local session="" picker_required=1
  if [[ -n "$forced_session" ]]; then
    validate_session_path "$forced_session" || exit 1
    session=$(cd "$forced_session" && pwd)
    qqq_assert_session_resumable "$session" || exit 1
    acquire_lock "$session" || exit 1
    picker_required=0
  fi

  while :; do
    if (( picker_required )); then
      local picked_session=""
      picked_session=$(select_session) || {
        printf '[qqq] session selection aborted\n'
        break
      }
      if [[ -n "$session" && "$picked_session" != "$session" ]]; then
        release_session_lock
        session=""
      fi
      if [[ -z "$session" ]]; then
        qqq_assert_session_resumable "$picked_session" || continue
        acquire_lock "$picked_session" || continue
        session="$picked_session"
      fi
      picker_required=0
    fi

    if (( resume_push )); then
      local resumed_session rc
      resumed_session=$(action_worktree_merge "$session" 1)
      rc=$?
      if [[ -n "$resumed_session" && "$resumed_session" != "$session" ]]; then
        session="$resumed_session"
      fi
      release_session_lock
      printf '[qqq] bye. Session: %s\n' "$session"
      exit "$rc"
    fi

    while :; do
      local suggested
      suggested=$(detect_next_phase "$session")
      local action
      action=$(select_action "$session" "$suggested") || action="back-to-session-list"
      case "$action" in
        req-clarifier)
          run_agent "$session" req-clarifier
          ;;
        ui-outliner)
          guard_file "phase1-spec.md" "$session/phase1-spec.md" || continue
          run_agent "$session" ui-outliner "$session/phase1-spec.md"
          ;;
        nltp-interviewer)
          guard_file "phase1-spec.md" "$session/phase1-spec.md" || continue
          run_agent "$session" nltp-interviewer "$session/phase1-spec.md"
          ;;
        tech-interviewer)
          guard_file "phase1-spec.md" "$session/phase1-spec.md" || continue
          run_agent "$session" tech-interviewer "$session/phase1-spec.md"
          ;;
        code-planner)
          guard_file "phase1-spec.md" "$session/phase1-spec.md" || continue
          guard_file "phase1-tech-spec.md" "$session/phase1-tech-spec.md" || continue
          run_agent "$session" code-planner "$session/phase1-spec.md" 1
          ;;
        code-implementer)
          guard_file "phase2-code-plan.md" "$session/phase2-code-plan.md" || continue
          qqq_guard_phase2_review_completed "$session" || continue
          run_agent "$session" code-implementer "$session/phase2-code-plan.md" 1
          ;;
        resolve-rebase-conflict)
          action_resolve_rebase_conflict "$session"
          ;;
        merge-resume-push)
          local resumed_session resume_rc
          resumed_session=$(action_worktree_merge "$session" 1)
          resume_rc=$?
          if [[ -n "$resumed_session" && "$resumed_session" != "$session" && -d "$resumed_session" ]]; then
            release_session_lock
            if acquire_lock "$resumed_session"; then
              session="$resumed_session"
            else
              session=""
              picker_required=1
              break
            fi
          fi
          (( resume_rc == 0 )) || continue
          ;;
        rewind)
        rewind_session "$session"
        ;;
        worktree-open)
          action_worktree_open "$session"
          ;;
        worktree-merge)
          local merged_session merge_rc
          merged_session=$(action_worktree_merge "$session")
          merge_rc=$?
          if [[ -n "$merged_session" && "$merged_session" != "$session" && -d "$merged_session" ]]; then
            release_session_lock
            if acquire_lock "$merged_session"; then
              session="$merged_session"
            else
              session=""
              picker_required=1
              break
            fi
          fi
          (( merge_rc == 0 )) || continue
          ;;
        worktree-remove)
          action_worktree_remove "$session" selective
          ;;
        view-artifacts)
          view_artifacts "$session"
          ;;
        open-session-dir)
          open_session_dir "$session"
          ;;
        back-to-session-list|"")
          picker_required=1
          break
          ;;
        *)
          printf '[qqq] unknown action: %s\n' "$action" >&2
          ;;
      esac
    done
  done

  release_session_lock
  if [[ -n "$session" ]]; then
    printf '[qqq] bye. Session: %s\n' "$session"
  else
    printf '[qqq] bye.\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
