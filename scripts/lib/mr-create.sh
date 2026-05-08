# qqq lib — mr-create
# Stage 5 GitLab merge-request creation. action_dev_mr_create wraps
# `glab mr create` with the qqq-specific preflight + workflow-event
# logging used by the dev-mr-create menu action. Consumes glab plus
# the qqq_session_state_* / qqq_log_workflow_event helpers (loaded
# transitively through the existing source chain).

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
