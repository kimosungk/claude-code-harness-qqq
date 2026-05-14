# qqq lib — mr-create
# Stage 5 GitLab merge-request creation. action_dev_mr_create wraps
# `glab mr create` with the qqq-specific preflight + workflow-event
# logging used by the dev-mr-create menu action. Consumes glab plus
# the qqq_session_state_* / qqq_log_workflow_event helpers (loaded
# transitively through the existing source chain).
#
# D8/D9: when QQQ_MR_RENDER != "0" (default ON), action_dev_mr_create
# auto-locates the most recent active session that has a phase0-issue.md,
# pulls iid + labels + assignees from its frontmatter, and synthesizes
# `Closes #<iid>` plus collapsible <details> summaries of phase1/2/3
# artifacts into the MR description. It also propagates --label/--assignee
# from phase0-issue.md to glab. Set QQQ_MR_RENDER=0 to fall back to the
# legacy static-template behaviour.

# ---------------------------------------------------------------------------
# D8/D9 helpers (private)
# ---------------------------------------------------------------------------

# Max bytes injected into a single MR description. GitLab accepts ~1MB but
# review UI gets unwieldy past ~64KB; we cap conservatively.
_QQQ_MR_DESC_MAX_BYTES=65536
_QQQ_MR_PHASE_HEAD_LINES=30

# Extract iid from a session's phase0-issue.md frontmatter. Reuses the same
# regex as qqq_phase0_iid_collisions (phase0-issue.sh:23). Empty on miss.
_qqq_mr_extract_iid() {
  local session_dir="$1"
  local f="$session_dir/phase0-issue.md"
  [[ -f "$f" ]] || return 0
  sed -nE 's/^iid:[[:space:]]*"?([0-9]+)"?.*/\1/p' "$f" | head -1
}

# Extract a YAML inline JSON array field (labels / assignees) from a session's
# phase0-issue.md and emit as CSV. Empty on miss or when the array is `[]`.
# Matches the format written by phase0-issue.sh:319-320.
_qqq_mr_extract_yaml_array() {
  local session_dir="$1" field="$2"
  local f="$session_dir/phase0-issue.md"
  [[ -f "$f" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local line
  line=$(sed -nE "s/^${field}:[[:space:]]*(.+)$/\1/p" "$f" | head -1)
  [[ -n "$line" ]] || return 0
  [[ "$line" == "[]" ]] && return 0
  printf '%s' "$line" | jq -r '. | join(",")' 2>/dev/null
}

# Locate the most-recent active session that owns a phase0-issue.md with an
# extractable iid. Used to associate the repo-scope MR action with a session
# whose phase artifacts can be inlined. Empty stdout on miss.
_qqq_mr_find_session() {
  local sessions sess mtime latest_mtime=0 latest_sess=""
  sessions=$(list_sessions active 2>/dev/null) || return 0
  while IFS=$'\t' read -r _label sess _rest; do
    [[ -n "$sess" ]] || continue
    [[ -f "$sess/phase0-issue.md" ]] || continue
    [[ -n "$(_qqq_mr_extract_iid "$sess")" ]] || continue
    mtime=$(stat -c %Y "$sess" 2>/dev/null || stat -f %m "$sess" 2>/dev/null || echo 0)
    if (( mtime > latest_mtime )); then
      latest_mtime=$mtime
      latest_sess="$sess"
    fi
  done <<<"$sessions"
  [[ -n "$latest_sess" ]] && printf '%s' "$latest_sess"
}

# Emit the head of a phase artifact (best-effort summary). Skips silently when
# the file is absent. Truncates beyond _QQQ_MR_PHASE_HEAD_LINES with a marker.
# Phase artifacts do not enforce a fixed heading structure, so v1 takes the
# first N lines verbatim — readers click through to the session for the rest.
_qqq_mr_artifact_summary() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local total
  total=$(wc -l <"$file" 2>/dev/null | tr -d ' ')
  head -n "$_QQQ_MR_PHASE_HEAD_LINES" "$file"
  if [[ -n "$total" ]] && (( total > _QQQ_MR_PHASE_HEAD_LINES )); then
    printf '\n… (truncated — %d more lines in %s)\n' \
      "$(( total - _QQQ_MR_PHASE_HEAD_LINES ))" "$(basename "$file")"
  fi
}

# Render a full MR description: <base_body> + Closes #<iid> + three <details>
# blocks for phase1/2/3 artifacts (skipped when missing) + qqq metadata block.
# Caps total output at _QQQ_MR_DESC_MAX_BYTES bytes.
_qqq_mr_render_description() {
  local session_dir="$1" base_body="$2" iid="$3" \
        dev_branch="$4" target_branch="$5"
  local rendered phase1 phase2 phase3 slug
  slug=$(qqq_slug_from_session_dir "$session_dir" 2>/dev/null || basename "$session_dir")
  phase1=$(_qqq_mr_artifact_summary "$session_dir/phase1-spec.md")
  phase2=$(_qqq_mr_artifact_summary "$session_dir/phase2-code-plan.md")
  phase3=$(_qqq_mr_artifact_summary "$session_dir/phase3-implement-log.md")

  rendered="$base_body"$'\n\n---\n'
  if [[ -n "$iid" ]]; then
    rendered+=$'\nCloses #'"$iid"$'\n'
  fi
  if [[ -n "$phase1" ]]; then
    rendered+=$'\n<details><summary>spec (phase1)</summary>\n\n'"$phase1"$'\n\n</details>\n'
  fi
  if [[ -n "$phase2" ]]; then
    rendered+=$'\n<details><summary>code plan (phase2)</summary>\n\n'"$phase2"$'\n\n</details>\n'
  fi
  if [[ -n "$phase3" ]]; then
    rendered+=$'\n<details><summary>implement log (phase3)</summary>\n\n'"$phase3"$'\n\n</details>\n'
  fi
  rendered+=$'\n<details><summary>qqq metadata</summary>\n\n'
  rendered+=$'session: '"$slug"$'\n'
  rendered+=$'source: '"$dev_branch"$' → '"$target_branch"$'\n'
  rendered+=$'generated: '"$(qqq_iso_timestamp 2>/dev/null || date -Iseconds)"$'\n'
  rendered+=$'\n</details>\n'

  local rendered_bytes
  rendered_bytes=${#rendered}
  if (( rendered_bytes > _QQQ_MR_DESC_MAX_BYTES )); then
    rendered="${rendered:0:_QQQ_MR_DESC_MAX_BYTES}"
    rendered+=$'\n\n… (truncated — MR description exceeded '"$_QQQ_MR_DESC_MAX_BYTES"$' bytes)\n'
  fi
  printf '%s' "$rendered"
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

  # Fallback: inline qqq template (also the rendered-mode base when no project
  # template was picked). Path resolution mirrors the original shipping path.
  local plugin_tmpl="$HOME/.claude/plugins/local/hskim-plugins/plugins/qqq/templates/gitlab-mr-default.md"
  local inline_body=""
  if [[ -z "$use_project_template" ]]; then
    if [[ -f "$plugin_tmpl" ]]; then
      inline_body=$(cat "$plugin_tmpl")
      printf '[qqq] no project template — using qqq inline template (no project file written).\n'
    else
      printf '[qqq] warning: qqq inline template not found at %s — empty description.\n' "$plugin_tmpl" >&2
    fi
  fi

  # --- D8/D9: rendered mode resolves a session and synthesizes description ---
  # QQQ_MR_RENDER=0 → opt out, behave exactly like pre-D8 code.
  local mr_render="${QQQ_MR_RENDER:-1}"
  local rendered_session="" rendered_iid="" rendered_labels="" rendered_assignees=""
  local rendered_description=""
  if [[ "$mr_render" != "0" ]]; then
    rendered_session=$(_qqq_mr_find_session 2>/dev/null || printf '')
    if [[ -n "$rendered_session" ]]; then
      rendered_iid=$(_qqq_mr_extract_iid "$rendered_session" 2>/dev/null || printf '')
      rendered_labels=$(_qqq_mr_extract_yaml_array "$rendered_session" labels 2>/dev/null || printf '')
      rendered_assignees=$(_qqq_mr_extract_yaml_array "$rendered_session" assignees 2>/dev/null || printf '')
      printf '[qqq] rendered mode: associating MR with session %s (iid=%s)\n' \
        "$(basename "$rendered_session")" "${rendered_iid:-?}" >&2
    else
      printf '[qqq] rendered mode: no active session with phase0-issue.md found — synthesizing without iid/labels.\n' >&2
    fi
    # Rendered base body = project template content (read directly) or inline
    # template fallback. We bypass --template entirely so phase artifacts can
    # be appended.
    local base_body="$inline_body"
    if [[ -n "$use_project_template" ]]; then
      base_body=$(cat "$tmpl_dir/$use_project_template.md" 2>/dev/null || printf '')
    fi
    rendered_description=$(_qqq_mr_render_description \
      "${rendered_session:-$leader_repo}" "$base_body" "$rendered_iid" \
      "$dev_branch" "$target_branch")
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
  if [[ "$mr_render" != "0" ]]; then
    glab_args+=(--description "$rendered_description")
    [[ -n "$rendered_labels"    ]] && glab_args+=(--label    "$rendered_labels")
    [[ -n "$rendered_assignees" ]] && glab_args+=(--assignee "$rendered_assignees")
  else
    if [[ -n "$use_project_template" ]]; then
      glab_args+=(--template "$use_project_template")
    elif [[ -n "$inline_body" ]]; then
      glab_args+=(--description "$inline_body")
    fi
  fi

  printf '[qqq] local %s is synced with origin/%s; proceeding with glab MR creation.\n' "$dev_branch" "$dev_branch"
  printf '[qqq] creating MR via glab...\n'
  ( cd "$leader_repo" && glab "${glab_args[@]}" )
  local rc=$?

  # Workflow-event log (uses session_dir when D8/D9 located one; otherwise the
  # leader repo so the JSONL goes under its .qqq/log.jsonl rather than being
  # silently dropped by qqq_log_workflow_event's session_dir guard).
  local log_target_dir="${rendered_session:-$leader_repo}"
  local log_result="completed"
  (( rc == 0 )) || log_result="error"
  local labels_count=0 assignees_count=0
  [[ -n "$rendered_labels"    ]] && labels_count=$(awk -F, '{print NF}' <<<"$rendered_labels")
  [[ -n "$rendered_assignees" ]] && assignees_count=$(awk -F, '{print NF}' <<<"$rendered_assignees")
  qqq_log_workflow_event "mr_create" "$log_result" "" "$log_target_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "rendered" "$([[ "$mr_render" != "0" ]] && echo 1 || echo 0)" \
    "has_iid" "$([[ -n "$rendered_iid" ]] && echo 1 || echo 0)" \
    "labels_count" "$labels_count" \
    "assignees_count" "$assignees_count" \
    "rc" "$rc"

  if (( rc != 0 )); then
    printf '[qqq] glab mr create failed (rc=%d). Check `glab auth status` and remote config.\n' "$rc" >&2
    return "$rc"
  fi
}
