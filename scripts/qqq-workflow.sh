#!/usr/bin/env bash
# qqq-workflow — fzf + tmux orchestrator for the qqq plugin phase workflow.
#
# New sessions bootstrap in leader-mode under
# ${QQQ_WORKS_DIR:-$PWD/claude-works}/YYYY-MM-DD_<slug>/. Code changes touch
# the leader checkout directly until the user picks `worktree-create`,
# which then promotes the session into a linked worktree at
# .qqq-worktrees/<slug>/.../claude-works/YYYY-MM-DD_<slug>/.
# Legacy pre-leader-mode sessions (no .qqq/session.json, no phase artifacts)
# remain visible for discard but cannot be resumed.
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
#   qqq --base|-b <ref>          # preset worktree-create base branch (e.g. origin/main, release/1.0)
#   picker keys                  # Enter selects, Delete discards active sessions
#
# Environment:
#   QQQ_WORKS_DIR  claude-works base (default: $PWD/claude-works)
#   QQQ_DEV_BRANCH origin dev branch name (default: dev)
#   QQQ_NO_FETCH=1 skip `git fetch origin <dev>` in session bootstrap/merge/MR preflight
#   QQQ_CLI_BASE_BRANCH  preset for worktree-create base (also settable via --base/-b)

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf '[qqq] requires bash 4+ (found %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

# Resolve lib dir relative to this entry script. Source order matters:
# bootstrap defines shared exports, dependency probes, fzf/prompt test
# injection, tmux guard, and per-session flock — all of which the rest of
# the script relies on.
__qqq_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
__qqq_lib_dir="$__qqq_script_dir/lib"

source "$__qqq_lib_dir/bootstrap.sh"

source "$__qqq_lib_dir/action-handlers.sh"

source "$__qqq_lib_dir/merge-archive.sh"

source "$__qqq_lib_dir/worktree-actions.sh"

source "$__qqq_lib_dir/phase0-issue.sh"

source "$__qqq_lib_dir/merge-protocol.sh"

source "$__qqq_lib_dir/mr-create.sh"

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
      --base|-b)
        QQQ_CLI_BASE_BRANCH="${2:?--base requires a branch ref (e.g. origin/main or release/1.0)}"
        export QQQ_CLI_BASE_BRANCH
        shift 2
        ;;
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
        register-issue)
          action_register_issue "$session"
          ;;
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
        worktree-create)
          local created_session create_rc
          created_session=$(action_worktree_create "$session")
          create_rc=$?
          if [[ -n "$created_session" && "$created_session" != "$session" && -d "$created_session" ]]; then
            release_session_lock
            if acquire_lock "$created_session"; then
              session="$created_session"
            else
              session=""
              picker_required=1
              break
            fi
          fi
          (( create_rc == 0 )) || continue
          ;;
        worktree-merge-preview)
          action_worktree_merge_preview "$session" || true
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
