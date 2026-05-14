# qqq lib — session-mgmt
# Active/legacy/completed session listing, status detection, slug
# resolution, leader-mode bootstrapping (create_new_session), session
# state read/write (session.json), and merge-state queries used by
# the phase picker. Loaded after lib/worktree-helpers.sh.
source "$__qqq_lib_dir/worktree-helpers.sh"
# A2: glab cache helpers used by list_sessions to inline #issue/!MR signals
# into picker rows. Pure read-only; safe to load even when glab is missing.
source "$__qqq_lib_dir/glab-cache.sh"
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
  # A2: refresh the glab issue/MR cache once per picker entry (TTL-honored).
  # qqq_emit_session_row → qqq_session_picker_label reads it for the
  # `#42 opened · MR!17 draft` inline signal. Failures are silent.
  local _list_leader_repo
  if _list_leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null); then
    qqq_glab_index_ensure "$_list_leader_repo" 2>/dev/null || true
  fi
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

  # base_branch from .qqq/session.json (set by worktree-create).
  if qqq_session_state_exists "$dir"; then
    local base_branch_pv
    base_branch_pv=$(qqq_session_state_get "$dir" base_branch 2>/dev/null)
    if [[ -n "$base_branch_pv" ]]; then
      printf 'base_branch: %s\n' "$base_branch_pv"
    else
      printf 'base_branch: (unset — set by worktree-create)\n'
    fi
  fi
  printf '\n'

  printf 'Phase progress:\n'
  for f in phase0-issue.md \
           phase1-spec.md phase1-ui-outline.md phase1-ui-outline.html phase1-nltp.md \
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

# Resolve a base branch for worktree creation.
#   1. QQQ_CLI_BASE_BRANCH (set by --base/-b) wins without prompting.
#   2. Empty input    -> origin/<dev>.
#   3. Literal ?      -> fzf over `git branch -a` (locals + origin/*).
#   4. Anything else  -> the literal value.
qqq_prompt_base_branch() {
  local dev_branch="$1" leader_repo="${2:-$PWD}"

  if [[ -n "${QQQ_CLI_BASE_BRANCH:-}" ]]; then
    printf '%s' "$QQQ_CLI_BASE_BRANCH"
    return 0
  fi

  local default_ref="origin/$dev_branch"
  local raw
  qqq_read_prompt "[qqq] base branch [$default_ref] (? for fzf): " raw || return 1

  if [[ -z "$raw" ]]; then
    printf '%s' "$default_ref"
    return 0
  fi

  if [[ "$raw" == "?" ]]; then
    local picked
    picked=$(
      git -C "$leader_repo" branch -a 2>/dev/null \
        | sed -E 's/^[* +]+//; s/ ->.*//' \
        | sed -E 's@^remotes/@@' \
        | grep -E '^(origin/|[^/]+$)' \
        | sort -u \
        | qqq_fzf --prompt='base branch > ' --query "$default_ref" --height=40%
    ) || return 1
    [[ -n "$picked" ]] || return 1
    printf '%s' "$picked"
    return 0
  fi

  printf '%s' "$raw"
}

create_new_session() {
  local slug
  qqq_read_prompt '[qqq] feature slug (kebab-case): ' slug || return 1
  slug=$(printf '%s' "$slug" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')
  if [[ -z "$slug" ]]; then
    printf '[qqq] empty slug; aborting.\n' >&2
    return 1
  fi

  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) || leader_repo=""
  if [[ -z "$leader_repo" ]]; then
    printf '[qqq] not inside a git repo — cannot create session.\n' >&2
    return 1
  fi

  # D10a — slug collision across active session locations.
  local collision="" existing wt_path
  for existing in "$QQQ_WORKS_DIR"/*_"$slug"; do
    [[ -d "$existing" ]] || continue
    collision="$existing"
    break
  done
  if [[ -z "$collision" ]]; then
    wt_path=$(qqq_worktree_path_for "$leader_repo" "$slug")
    if [[ -d "$wt_path" ]]; then
      collision="$wt_path"
    fi
  fi
  if [[ -n "$collision" ]]; then
    printf '[qqq] active session for slug %q already exists: %s\n' "$slug" "$collision" >&2
    printf '[qqq] resume the existing session, or pick a different slug.\n' >&2
    return 1
  fi

  local session_name session_dir created_at
  session_name="$(date +%Y-%m-%d)_${slug}"
  session_dir="$QQQ_WORKS_DIR/$session_name"
  if [[ -d "$session_dir" ]]; then
    printf '[qqq] session dir already exists: %s\n' "$session_dir" >&2
    return 1
  fi

  mkdir -p "$session_dir/.qqq" || {
    printf '[qqq] failed to mkdir %s\n' "$session_dir" >&2
    return 1
  }

  created_at=$(qqq_iso_timestamp)
  if ! qqq_session_state_write "$session_dir" "$slug" "$created_at" "" "" "$leader_repo"; then
    printf '[qqq] failed to write session.json\n' >&2
    rmdir "$session_dir/.qqq" "$session_dir" 2>/dev/null || true
    return 1
  fi

  qqq_log_workflow_event "session_create" "completed" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "slug" "$slug" \
    "leader_repo" "$leader_repo"

  printf '[qqq] created leader-mode session: %s\n' "$session_dir" >&2
  printf '[qqq] no worktree yet — pick `worktree-create` when ready to isolate code changes.\n' >&2
  printf '%s' "$session_dir"
}

