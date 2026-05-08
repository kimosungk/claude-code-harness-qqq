# qqq lib — worktree-helpers
# Repository / linked-worktree path math, session-dir → worktree mapping,
# branch lookups, ignore-pattern bookkeeping, and the broader
# "Stage 1 foundation" surface that every higher layer depends on.
# Loaded right after lib/bootstrap.sh by scripts/qqq-workflow.sh.
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

# Resolve the effective dev branch for a session: prefer base_branch from
# .qqq/session.json (set by worktree-create); fall back to QQQ_DEV_BRANCH
# with a stderr warning. Output is the bare branch name (no `origin/` prefix);
# callers always do `git fetch origin "$branch"` etc.
qqq_session_dev_branch() {
  local session_dir="$1"
  local raw=""
  raw=$(qqq_session_state_get "$session_dir" base_branch 2>/dev/null || printf '')
  if [[ -z "$raw" ]]; then
    local fb
    fb=$(qqq_origin_dev_branch)
    printf '[qqq] warning: session.json missing base_branch; falling back to origin/%s\n' "$fb" >&2
    printf '%s' "$fb"
    return 0
  fi
  printf '%s' "${raw#origin/}"
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

  # Current-format leader-mode session: .qqq/session.json or any phase artifact present.
  # These sessions live under leader's claude-works/ but are resumable.
  [[ -f "$session_dir/.qqq/session.json" ]] && return 1
  [[ -f "$session_dir/phase0-issue.md" \
     || -f "$session_dir/phase1-spec.md" \
     || -f "$session_dir/phase1-tech-spec.md" \
     || -f "$session_dir/phase2-code-plan.md" \
     || -f "$session_dir/phase3-implement-log.md" ]] && return 1

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

qqq_session_state_path() {
  printf '%s/.qqq/session.json' "$1"
}

qqq_session_state_write() {
  local session_dir="$1" slug="$2" created_at="$3"
  local base_branch="$4" worktree_path="$5" leader_repo="$6"
  local state_path
  state_path=$(qqq_session_state_path "$session_dir")
  qqq_write_json_file "$state_path" \
    schema_version "1" \
    slug "$slug" \
    created_at "$created_at" \
    base_branch "$base_branch" \
    worktree_path "$worktree_path" \
    leader_repo "$leader_repo"
}

qqq_session_state_get() {
  local session_dir="$1" key="$2"
  qqq_json_read_string_key "$(qqq_session_state_path "$session_dir")" "$key"
}

qqq_session_state_exists() {
  [[ -f $(qqq_session_state_path "$1") ]]
}

# Atomic field update: read all known fields, override one, re-write.
# Unknown keys return 2 (caller bug).
qqq_session_state_set_field() {
  local session_dir="$1" key="$2" value="$3"
  local state_path slug created_at base_branch worktree_path leader_repo
  state_path=$(qqq_session_state_path "$session_dir")
  [[ -f "$state_path" ]] || return 1
  slug=$(qqq_session_state_get "$session_dir" slug 2>/dev/null || printf '')
  created_at=$(qqq_session_state_get "$session_dir" created_at 2>/dev/null || printf '')
  base_branch=$(qqq_session_state_get "$session_dir" base_branch 2>/dev/null || printf '')
  worktree_path=$(qqq_session_state_get "$session_dir" worktree_path 2>/dev/null || printf '')
  leader_repo=$(qqq_session_state_get "$session_dir" leader_repo 2>/dev/null || printf '')
  case "$key" in
    slug)          slug="$value" ;;
    created_at)    created_at="$value" ;;
    base_branch)   base_branch="$value" ;;
    worktree_path) worktree_path="$value" ;;
    leader_repo)   leader_repo="$value" ;;
    *) printf '[qqq] qqq_session_state_set_field: unknown key %q\n' "$key" >&2; return 2 ;;
  esac
  qqq_session_state_write "$session_dir" "$slug" "$created_at" "$base_branch" "$worktree_path" "$leader_repo"
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

