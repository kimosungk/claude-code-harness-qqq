# qqq lib — merge-protocol
# Stage 3 merge orchestration: action_worktree_merge runs the dev-branch
# rebase + push + cleanup pipeline (driving the Stage 4 archive primitives
# from merge-archive), and _merge_cleanup_prompt is the post-merge
# interactive cleanup prompt invoked at the end. Consumes the worktree-
# helpers / session-mgmt accessors plus archive_session_to_completed and
# commit_session_artifacts_if_dirty from merge-archive.sh.

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
  dev_branch=$(qqq_session_dev_branch "$session_dir")
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
