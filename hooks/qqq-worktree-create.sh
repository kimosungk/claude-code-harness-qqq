#!/usr/bin/env bash
# qqq-worktree-create — WorktreeCreate hook for the qqq plugin.
#
# Registered at user scope via `qqq install` (see scripts/qqq). User-scope is
# required because Claude Code v2.1.144 does NOT route WorktreeCreate to
# plugin-level hooks/hooks.json (verified empirically; docs do not document the
# distinction). All other qqq hooks (PreToolUse, SessionStart) remain at the
# plugin scope.
#
# Behaviour gates on the presence of a *staging file* at
#   $HOME/.claude/qqq-staging/<slug>.json
# which is written by `qqq new` immediately before invoking
# `claude --bg --worktree <slug> ...`.
#
#   ┌────────────────────────────────────────┬─────────────────────────────────┐
#   │ With staging file (qqq mode)           │ Without staging file (default)  │
#   ├────────────────────────────────────────┼─────────────────────────────────┤
#   │ branch  = <slug>                       │ branch  = worktree-<slug>       │
#   │ path    = <leader>/.claude/worktrees/  │ path    = (same)                │
#   │           <slug>                       │                                 │
#   │ sentinel + claude-works/<date>_<slug>  │ no sentinel, no claude-works    │
#   │ session cwd = <wt>/<caller subdir>     │ session cwd = <wt>              │
#   │ optional phase0-issue.md fetch+commit  │ no phase0 handling              │
#   └────────────────────────────────────────┴─────────────────────────────────┘
#
# This keeps non-qqq `claude --worktree` invocations identical to the Claude
# Code default behaviour (modulo `.worktreeinclude`, which is unavoidably
# disabled once any WorktreeCreate hook is registered — docs/en/worktrees).
#
# Contract (docs/en/hooks WorktreeCreate):
#   stdin  : JSON {session_id, transcript_path, cwd, hook_event_name, name}
#   stdout : absolute path used as the session's working directory
#   stderr : diagnostics (logged only)
#   nonzero exit : worktree creation aborts

set -u  # not -e: we want to control failure paths explicitly

die() {
  printf '[qqq-worktree-create] %s\n' "$*" >&2
  exit 1
}
warn() {
  printf '[qqq-worktree-create] WARN: %s\n' "$*" >&2
}

command -v jq >/dev/null 2>&1 || die "jq required"
command -v git >/dev/null 2>&1 || die "git required"

# ---- parse input -----------------------------------------------------------
input=$(cat)
[[ -n "$input" ]] || die "empty stdin"

slug=$(jq -r '.name // empty' <<<"$input")
caller_cwd=$(jq -r '.cwd // empty' <<<"$input")

[[ -n "$slug" ]]       || die "missing .name in hook input"
[[ -n "$caller_cwd" ]] || die "missing .cwd in hook input"
[[ -d "$caller_cwd" ]] || die "caller cwd does not exist: $caller_cwd"

# Slug sanity: lowercase alnum + _-, must start with [a-z0-9].
# Use the same charset Claude Code itself accepts for --worktree values.
[[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || die "invalid slug (must match [a-z0-9_-], start with [a-z0-9]): $slug"

# ---- leader root + subdir --------------------------------------------------
# Use --path-format=absolute so we never get a relative ../.git result (which
# caused the v3.x repo_slug incident — slug ".." escaped into ~/.claude/).
common_dir=$(git -C "$caller_cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "caller cwd is not inside a git repo: $caller_cwd"
leader_root=$(dirname "$common_dir")
[[ -d "$leader_root" ]] || die "computed leader_root does not exist: $leader_root"

# subdir = caller_cwd relative to leader_root. Empty when caller is at root.
if [[ "$caller_cwd" == "$leader_root" ]]; then
  subdir=""
elif [[ "$caller_cwd" == "$leader_root"/* ]]; then
  subdir="${caller_cwd#"$leader_root"/}"
else
  warn "caller_cwd not under leader_root — landing at worktree root (caller=$caller_cwd, leader=$leader_root)"
  subdir=""
fi

# ---- mode gate: staging file presence --------------------------------------
staging_dir="$HOME/.claude/qqq-staging"
staging_file="$staging_dir/$slug.json"
if [[ -f "$staging_file" ]]; then
  qqq_mode=1
  branch="$slug"
else
  qqq_mode=0
  branch="worktree-$slug"
fi

# ---- worktree creation -----------------------------------------------------
wt_path="$leader_root/.claude/worktrees/$slug"

if [[ -e "$wt_path" ]]; then
  die "worktree path already exists: $wt_path (remove with 'git worktree remove')"
fi
if git -C "$leader_root" show-ref --verify --quiet "refs/heads/$branch"; then
  die "branch '$branch' already exists in $leader_root (delete with 'git branch -D $branch' or pick another slug)"
fi

mkdir -p "$(dirname "$wt_path")"

# Branch from local HEAD. Default Claude behaviour branches from origin/HEAD
# (or the worktree.baseRef setting); using HEAD matches v3.x qqq behaviour
# where workflows historically branch from whatever the user is on (dev/etc).
if ! git -C "$leader_root" worktree add -b "$branch" "$wt_path" HEAD >&2; then
  die "git worktree add failed: $wt_path (branch $branch)"
fi

# ---- qqq-mode extras (sentinel + phase0) -----------------------------------
phase0_committed=0
if (( qqq_mode )); then
  date_slug=$(date +%Y-%m-%d)
  session_dir="$wt_path/claude-works/${date_slug}_${slug}"
  mkdir -p "$session_dir"

  # Sentinel pins the active session_dir AND caller subdir. Replaces mtime-based
  # infer_session_dir (retired in v3.3): unambiguous, lifecycle-bound to the
  # worktree, archive-safe (merge-mr clears it when claude-works/ →
  # claude-works-completed/).
  #
  # Format (always 2 lines for v3.3+ writers):
  #   line 1: absolute session_dir
  #   line 2: caller subdir relative to wt root (empty line when caller was at
  #           wt root). Distinguishes "root intent" (2-line, empty line 2) from
  #           "legacy 1-line sentinel" (read_active_session_subdir falls back to
  #           empty-string for legacy sentinels rather than treating absence as
  #           root intent — the two have indistinguishable semantics in this
  #           layer but the writer always emits 2 lines).
  #
  # Atomic write via tmp+rename in the same directory (rename(2) is atomic on
  # the same filesystem). Reader cannot observe a partial sentinel.
  sentinel_path="$wt_path/.qqq-current-session"
  sentinel_tmp="$wt_path/.qqq-current-session.tmp.$$"
  printf '%s\n%s\n' "$session_dir" "$subdir" > "$sentinel_tmp" \
    || die "failed to write sentinel tmp: $sentinel_tmp"
  mv "$sentinel_tmp" "$sentinel_path" \
    || die "failed to rename sentinel: $sentinel_tmp → $sentinel_path"

  issue_n=$(jq -r '.issue // empty' "$staging_file")
  brief=$(jq -r '.brief // empty' "$staging_file")

  if [[ -n "$issue_n" ]]; then
    if ! command -v glab >/dev/null 2>&1; then
      warn "staging requested issue #$issue_n but glab is not installed — phase0-issue.md skipped"
    else
      phase0_path="$session_dir/phase0-issue.md"
      if json=$(glab issue view "$issue_n" --output json 2>/dev/null); then
        printf '%s' "$json" | jq -r --arg iid "$issue_n" '
          def label_value: if type == "string" then . else (.title // .name // "") end;
          def assignee_value: if type == "string" then . else (.username // .login // "") end;
          [
            "---",
            "iid: " + $iid,
            "state: " + ((.state // "") | @json),
            "web_url: " + ((.web_url // "") | @json),
            "title: " + ((.title // "") | @json),
            "labels: " + ([(.labels // [])[]? | label_value | select(length > 0)] | tostring),
            "assignees: " + ([(.assignees // [])[]? | assignee_value | select(length > 0)] | tostring),
            "---",
            "",
            "# " + (.title // "") + " (issue #" + $iid + ")",
            "",
            (.description // "")
          ] | join("\n")
        ' > "$phase0_path"
        if git -C "$wt_path" add "claude-works/${date_slug}_${slug}/phase0-issue.md" >&2 \
           && git -C "$wt_path" commit -m "phase0: $slug (issue #$issue_n)" >&2; then
          phase0_committed=1
        else
          warn "phase0 auto-commit failed — phase0-issue.md written but not committed"
        fi
      else
        warn "glab issue view $issue_n failed — phase0-issue.md skipped (check 'glab auth status')"
      fi
    fi
  fi

  # Brief is consumed by the agent's first user turn (build_initial_prompt in
  # scripts/qqq); the hook only ensures the staging file is cleaned up here.
  : "${brief:=}"

  # Consume the staging file (idempotent re-creation guard).
  rm -f "$staging_file"
fi

# ---- final stdout ----------------------------------------------------------
# qqq mode: session cwd = worktree root + caller's subdir (qqq new from
# monorepo/frontend lands inside <wt>/frontend).
# default mode: session cwd = worktree root (matches Claude Code default).
if (( qqq_mode )) && [[ -n "$subdir" && -d "$wt_path/$subdir" ]]; then
  session_cwd="$wt_path/$subdir"
else
  session_cwd="$wt_path"
fi

printf '[qqq-worktree-create] OK slug=%s mode=%s wt=%s subdir=%s phase0=%s\n' \
  "$slug" "$([[ $qqq_mode -eq 1 ]] && echo qqq || echo default)" \
  "$wt_path" "${subdir:-(root)}" "$phase0_committed" >&2

echo "$session_cwd"
