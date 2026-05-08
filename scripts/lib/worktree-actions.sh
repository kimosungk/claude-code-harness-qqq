# qqq lib — worktree-actions
# Stage 2 worktree CRUD plus the rebase-conflict launcher.
# Owns the leader→worktree promotion (qqq_bootstrap_session_worktree
# and its rollback_worktree_create unwinder) and the four interactive
# actions wired to the session menu: action_worktree_create / _open /
# _remove, plus action_resolve_rebase_conflict. qqq_branch_checked_out
# _elsewhere is a remove-time guard helper. Consumes worktree-helpers
# primitives plus session-mgmt status accessors (loaded transitively
# via action-handlers).

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
  local explicit_base_branch="${3:-}"
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
  # base_ref is what the worktree will branch from. Default origin/<dev>.
  # explicit_base_branch (Stage 5) lets the user override (e.g. origin/main).
  local base_ref="$explicit_base_branch"
  [[ -n "$base_ref" ]] || base_ref="origin/$dev_branch"

  if [[ "${QQQ_NO_FETCH:-0}" != "1" ]]; then
    # Fetch only when base_ref is an origin/* ref. Bare branch input (e.g.
    # `release/1.0`) is assumed to be a local branch already present;
    # forcing `fetch origin <dev>` here would fail in repos that do not
    # have an `origin/<dev>` (e.g., custom QQQ_DEV_BRANCH never pushed).
    if [[ "$base_ref" == origin/* ]]; then
      local _fetch_branch="${base_ref#origin/}"
      if ! git -C "$leader_repo" fetch origin "$_fetch_branch" 2>/dev/null; then
        printf '[qqq] `git fetch origin %s` failed. Set QQQ_NO_FETCH=1 to skip, or check remote/auth.\n' "$_fetch_branch" >&2
        return 1
      fi
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
    # Validate base_ref. `git worktree add -b <new> <path> <start>` does NOT
    # auto-resolve <start> to origin/<start> when only the remote-tracking
    # ref exists (unlike `git checkout`). So if the user typed a bare ref
    # like "release/1.0" and only origin/release/1.0 exists, we must
    # rewrite base_ref to the explicit remote-tracking form.
    if [[ "$base_ref" == origin/* ]]; then
      local _rb="${base_ref#origin/}"
      if ! qqq_branch_exists "$leader_repo" "$_rb" remote; then
        printf '[qqq] %s not found. Push it first or pick a different base.\n' "$base_ref" >&2
        return 1
      fi
    elif qqq_branch_exists "$leader_repo" "$base_ref" local; then
      : # local branch present; worktree add can use it directly
    elif qqq_branch_exists "$leader_repo" "$base_ref" remote; then
      printf '[qqq] base branch %s exists only as origin/%s — using origin/%s.\n' \
        "$base_ref" "$base_ref" "$base_ref" >&2
      base_ref="origin/$base_ref"
    else
      printf '[qqq] base branch %s not found (local or remote).\n' "$base_ref" >&2
      return 1
    fi
    if ! git -C "$leader_repo" worktree add -b "$branch" "$wt_path" "$base_ref" >&2; then
      printf '[qqq] `git worktree add -b %s` from %s failed.\n' "$branch" "$base_ref" >&2
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
      # N2 hardening: cp + diff -r verification before rm catches
      # truncated content, symlink mismatch, or partial copies.
      if cp -a "$source_session_dir/." "$new_session_dir/" 2>/dev/null \
         && diff -r "$source_session_dir" "$new_session_dir" >/dev/null 2>&1 \
         && rm -rf "$source_session_dir"; then
        :
      else
        printf '[qqq] failed to migrate session dir into worktree (cp/diff/rm). rolling back.\n' >&2
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

  # Persist worktree facts into session.json (Stage 1 schema). Used by
  # action_worktree_merge (Stage 6) and the picker preview (Stage 4).
  # session.json travelled along with the rest of the session via mv/cp above.
  if qqq_session_state_exists "$new_session_dir"; then
    if ! qqq_session_state_set_field "$new_session_dir" base_branch "$base_ref" \
       || ! qqq_session_state_set_field "$new_session_dir" worktree_path "$wt_path"; then
      printf '[qqq] failed to persist worktree fields in session.json. rolling back.\n' >&2
      rollback_worktree_create "$leader_repo" "$wt_path" "$branch" "$created_wt" "$created_branch" "$moved_from" "$moved_to"
      return 1
    fi
  fi

  qqq_release_repo_lock
  repo_lock_held=no
  trap - RETURN

  printf '[qqq] worktree ready: %s (branch %s, base %s)\n' "$wt_path" "$branch" "$base_ref" >&2
  printf '[qqq] session dir ready: %s\n' "$new_session_dir" >&2
  printf '%s' "$new_session_dir"
}

# Emits the new session_dir on stdout; status/info goes to stderr.
action_worktree_create() {
  local session_dir="$1"

  # Reject: session is already in a live worktree.
  local _wt_root
  _wt_root=$(qqq_session_dir_worktree "$session_dir")
  if [[ -n "$_wt_root" ]]; then
    printf '[qqq] session already lives in a worktree: %s\n' "$_wt_root" >&2
    return 1
  fi

  # Resolve base branch via Stage 3 prompt (or QQQ_CLI_BASE_BRANCH override).
  local leader_repo dev_branch base_branch
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || { printf '[qqq] not in a git repo.\n' >&2; return 1; }
  dev_branch=$(qqq_origin_dev_branch)
  base_branch=$(qqq_prompt_base_branch "$dev_branch" "$leader_repo") || {
    printf '[qqq] worktree-create cancelled.\n' >&2
    return 1
  }

  qqq_log_workflow_event "worktree_create" "started" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "source_session_dir" "$session_dir" \
    "base_branch" "$base_branch"
  local new_session_dir
  new_session_dir=$(qqq_bootstrap_session_worktree \
    "$(basename "$session_dir")" "$session_dir" "$base_branch") || {
    qqq_log_workflow_event "worktree_create" "error" "" "$session_dir" \
      "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
      "base_branch" "$base_branch"
    return 1
  }
  qqq_log_workflow_event "worktree_create" "completed" "" "$new_session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "base_branch" "$base_branch"
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
  dev_branch=$(qqq_session_dev_branch "$session_dir")

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
