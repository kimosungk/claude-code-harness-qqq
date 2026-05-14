# qqq lib — phase-detect
# Phase classification: maps a session_dir to its next-phase action
# (req-clarifier, code-planner, worktree-merge, done, etc.) and renders the
# title / description / status mark used by the action picker. Pure logic
# layer — depends on session-mgmt + worktree-helpers (transitively).
source "$__qqq_lib_dir/session-mgmt.sh"
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

  if [[ ! -f "$sess/phase0-issue.md" && ! -f "$sess/phase1-spec.md" ]]; then
    echo "register-issue"
  elif [[ ! -f "$sess/phase1-spec.md" ]]; then
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
    # phase3 done — recommend worktree-merge only if a worktree exists.
    # Leader-mode (autonomous, I1=a) sessions terminate with `done`; user
    # manages git themselves.
    local wt_root_for_done
    wt_root_for_done=$(qqq_session_dir_worktree "$sess")
    if [[ -n "$wt_root_for_done" ]]; then
      echo "worktree-merge"
    else
      echo "done"
    fi
  fi
}

phase_title() {
  case "$1" in
    register-issue)   echo 'Phase0 · register-issue' ;;
    req-clarifier)    echo 'Phase1 T1 · req-clarifier' ;;
    ui-outliner)      echo 'Phase1 T2 · ui-outliner' ;;
    nltp-interviewer) echo 'Phase1 T3 · nltp-interviewer' ;;
    tech-interviewer) echo 'Phase1 T4 · tech-interviewer' ;;
    code-planner)     echo 'Phase2 T1 · code-planner' ;;
    code-implementer) echo 'Phase3 T1 · code-implementer' ;;
    resolve-rebase-conflict) echo 'Recovery · resolve rebase conflict' ;;
    merge-resume-push) echo 'Recovery · resume pending push' ;;
    worktree-create)  echo 'Worktree · create (isolate session)' ;;
    worktree-open)    echo 'Worktree · open shell' ;;
    worktree-merge)   echo 'Worktree · merge session branch' ;;
    worktree-merge-preview) echo 'Worktree · merge dry-run (no side effects)' ;;
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
    register-issue)   echo 'Register or pick a GitLab issue and save it as phase0-issue.md. (Optional — req-clarifier accepts it as context if present.)' ;;
    req-clarifier)    echo 'Clarify the requirement and write phase1-spec.md.' ;;
    ui-outliner)      echo 'Draft a minimal UI outline and save phase1-ui-outline.md/html. (Optional — run before tech-interviewer if desired.)' ;;
    nltp-interviewer) echo 'Draft the Korean Gherkin NLTP in phase1-nltp.md. (Optional — run before tech-interviewer if desired.)' ;;
    tech-interviewer) echo 'Lock the technical spec in phase1-tech-spec.md. (Required before code-planner.)' ;;
    code-planner)     echo 'Build the reviewed implementation plan in phase2-code-plan.md.' ;;
    code-implementer) echo 'Execute the plan and write phase3-implement-log.md.' ;;
    resolve-rebase-conflict) echo 'Resume and resolve an in-progress worktree rebase conflict.' ;;
    merge-resume-push) echo 'Retry the saved push after a prior merge completed locally.' ;;
    worktree-create)  echo 'Create a linked git worktree from a chosen base branch and migrate this session into it.' ;;
    worktree-open)    echo 'Open a tmux shell window rooted at the current worktree.' ;;
    worktree-merge)   echo 'Rebase onto the recorded base branch, merge the session branch, push, and clean up.' ;;
    worktree-merge-preview) echo 'Simulate the rebase onto origin/dev in a throwaway worktree and report conflicts. Does NOT touch the dev branch or the session worktree.' ;;
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
    register-issue)
      [[ -f "$sess/phase0-issue.md" ]] && printf '●' || printf ' '
      ;;
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
    worktree-create)
      [[ -n "$wt_root" ]] && printf '●' || printf ' '
      ;;
    merge-resume-push)
      [[ "$merge_status" != "push_pending" ]] && [[ -n "$merge_status" ]] && printf '●' || printf ' '
      ;;
    *)
      printf ' '
      ;;
  esac
}
