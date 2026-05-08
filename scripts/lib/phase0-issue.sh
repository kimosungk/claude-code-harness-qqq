# qqq lib — phase0-issue
# Phase 0 — register an issue and write phase0-issue.md into a session
# directory. Pure shell action; no Claude agent. action_register_issue
# is the user-facing entry, qqq_phase0_iid_collisions is the duplicate-
# IID guard scanned across all active sessions before commit. Consumes
# glab/jq, the qqq_session_state_* family, and list_sessions (loaded
# transitively through the existing source chain). The HTML comment
# stripper inside action_register_issue uses delicate awk/jq quoting
# that must not be reflowed.

# Scan all active sessions (leader-mode + worktree-mode) for phase0-issue.md
# files matching the given iid. Prints colliding session paths to stdout.
# Excludes $exclude_session from the scan.
qqq_phase0_iid_collisions() {
  local iid="$1" exclude_session="$2"
  local sessions sess collision_iid
  sessions=$(list_sessions active 2>/dev/null) || return 0
  while IFS=$'\t' read -r _label sess _rest; do
    [[ -n "$sess" ]] || continue
    [[ "$sess" != "$exclude_session" ]] || continue
    [[ -f "$sess/phase0-issue.md" ]] || continue
    # Tolerate optional surrounding quotes in case of manual edits ("42" or 42).
    collision_iid=$(sed -nE 's/^iid:[[:space:]]*"?([0-9]+)"?.*/\1/p' "$sess/phase0-issue.md" | head -1)
    if [[ "$collision_iid" == "$iid" ]]; then
      printf '%s\n' "$sess"
    fi
  done <<<"$sessions"
}

# Phase 0 — register an issue (create new or pick existing) and write
# phase0-issue.md into session_dir. Shell-only action; no Claude agent.
# Returns 0 on success, non-zero on cancel/error. Stdout is unused (caller
# does not consume it); status messages go to stderr.
action_register_issue() {
  local session_dir="$1"

  if ! command -v glab >/dev/null 2>&1; then
    printf '[qqq] glab not installed — register-issue unavailable.\n' >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '[qqq] jq not installed — register-issue requires jq for JSON parsing.\n' >&2
    return 1
  fi

  local leader_repo
  leader_repo=$(qqq_leader_repo_from "$session_dir" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || { printf '[qqq] not in a git repo.\n' >&2; return 1; }

  # Branch picker: create new vs pick existing.
  local mode
  mode=$(printf '%s\n' \
    $'create\tCreate a new GitLab issue (title + description + labels + assignees)' \
    $'pick\tPick an existing GitLab issue from the repo' \
    | qqq_fzf --prompt='register-issue > ' --height=20% \
        --delimiter=$'\t' --with-nth=2 --accept-nth=1) || {
    printf '[qqq] register-issue cancelled.\n' >&2
    return 1
  }

  qqq_log_workflow_event "phase0_register_issue" "started" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "mode" "$mode"

  local iid="" web_url="" state="" title="" description="" labels_csv="" assignees_csv=""
  local source_action=""
  if [[ "$mode" == "create" ]]; then
    source_action="create"
    qqq_read_prompt "[qqq] issue title: " title || return 1
    if [[ -z "$title" ]]; then
      printf '[qqq] empty title — aborting.\n' >&2
      return 1
    fi

    # Description via $EDITOR. Tmp file under .qqq/ so the editor invocation
    # leaves no stray files in the session root.
    local desc_tmp="$session_dir/.qqq/phase0-desc.tmp.md"
    mkdir -p "$session_dir/.qqq"
    if [[ -f "$desc_tmp" ]]; then
      local resume_reply
      qqq_read_prompt "[qqq] previous draft found at $desc_tmp. resume? [Y/n]: " resume_reply || return 1
      if [[ "$resume_reply" == [Nn]* ]]; then
        rm -f "$desc_tmp"
      fi
    fi
    if [[ ! -f "$desc_tmp" ]]; then
      # HTML comment preamble (not '#'-line, so markdown ATX headings in the
      # body survive verbatim). Save and quit submits the body below.
      cat >"$desc_tmp" <<'EOF'
<!--
qqq Phase 0: type the GitLab issue description below.
This HTML comment block is stripped before submission.
Markdown headings (# H1, ## H2, ...) and any other content are preserved.
Save and quit to confirm. Empty body submits no description.
-->

EOF
    fi
    "${EDITOR:-vi}" "$desc_tmp" || {
      printf '[qqq] editor exited non-zero — aborting.\n' >&2
      return 1
    }
    # Strip HTML comment blocks (single- or multi-line), then trim leading/
    # trailing blank lines. Markdown # headings are preserved.
    description=$(awk '
      BEGIN { in_comment = 0 }
      {
        line = $0
        while (1) {
          if (in_comment) {
            idx = index(line, "-->")
            if (idx > 0) {
              line = substr(line, idx + 3)
              in_comment = 0
              continue
            } else {
              line = ""
              break
            }
          } else {
            idx = index(line, "<!--")
            if (idx > 0) {
              # keep text before the comment opener; resume scan after it
              pre  = substr(line, 1, idx - 1)
              line = substr(line, idx + 4)
              in_comment = 1
              # try to close on the same line; if not, the rest is dropped
              cidx = index(line, "-->")
              if (cidx > 0) {
                line = pre substr(line, cidx + 3)
                in_comment = 0
                continue
              } else {
                line = pre
                break
              }
            } else {
              break
            }
          }
        }
        print line
      }
    ' "$desc_tmp" | sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac)
    rm -f "$desc_tmp"

    # Labels (optional, multi). Use the project labels API for safe parsing —
    # `glab label list`'s text output truncates names with whitespace. JSON
    # via the api endpoint preserves names verbatim.
    local labels_picked=""
    local labels_raw
    labels_raw=$(cd "$leader_repo" && glab api 'projects/:id/labels?per_page=100' 2>/dev/null \
      | jq -r '.[]?.name // empty' 2>/dev/null)
    if [[ -n "$labels_raw" ]]; then
      labels_picked=$(printf '%s\n' "$labels_raw" \
        | qqq_fzf --multi --prompt='labels (TAB to multi-select, Enter when done) > ' --height=40% \
        || true)
    fi
    if [[ -n "$labels_picked" ]]; then
      labels_csv=$(printf '%s\n' "$labels_picked" | paste -sd, -)
    fi

    # Assignees (optional, multi). Use glab api on the project members
    # endpoint; fall back to empty if it fails (auth/permission).
    local assignees_picked=""
    local assignees_raw
    assignees_raw=$(cd "$leader_repo" && glab api 'projects/:id/members/all?per_page=100' 2>/dev/null \
      | jq -r '.[]?.username // empty' 2>/dev/null)
    if [[ -n "$assignees_raw" ]]; then
      assignees_picked=$(printf '%s\n' "$assignees_raw" \
        | qqq_fzf --multi --prompt='assignees (TAB to multi-select) > ' --height=40% \
        || true)
    fi
    if [[ -n "$assignees_picked" ]]; then
      assignees_csv=$(printf '%s\n' "$assignees_picked" | paste -sd, -)
    fi

    # Submit to GitLab via array-built argv (no string interpolation in glab).
    local -a glab_cmd=( glab issue create --no-editor --title "$title" )
    if [[ -n "$description" ]]; then
      glab_cmd+=( --description "$description" )
    else
      glab_cmd+=( --description "(no description)" )
    fi
    [[ -n "$labels_csv"    ]] && glab_cmd+=( --label    "$labels_csv" )
    [[ -n "$assignees_csv" ]] && glab_cmd+=( --assignee "$assignees_csv" )

    local create_out
    create_out=$( cd "$leader_repo" && "${glab_cmd[@]}" 2>&1 )
    local create_rc=$?
    printf '%s\n' "$create_out" >&2
    if (( create_rc != 0 )); then
      printf '[qqq] glab issue create failed (rc=%d).\n' "$create_rc" >&2
      qqq_log_workflow_event "phase0_register_issue" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "mode" "create" "reason" "glab create rc=$create_rc"
      return 1
    fi
    web_url=$(printf '%s\n' "$create_out" | grep -oE 'https?://[^[:space:]]+/issues/[0-9]+' | tail -1)
    iid="${web_url##*/}"
    if [[ -z "$iid" ]]; then
      printf '[qqq] could not parse iid from glab output.\n' >&2
      qqq_log_workflow_event "phase0_register_issue" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "mode" "create" "reason" "iid parse failed"
      return 1
    fi
    state="opened"
  else
    source_action="pick"
    # State filter (default opened).
    local state_pick
    state_pick=$(printf '%s\n' opened closed all \
      | qqq_fzf --prompt='state filter > ' --height=20% --query=opened) || {
      printf '[qqq] register-issue cancelled.\n' >&2
      return 1
    }

    local list_args=( issue list -O json -P 100 )
    case "$state_pick" in
      opened) list_args+=( --opened ) ;;
      closed) list_args+=( --closed ) ;;
      all)    list_args+=( --all ) ;;
    esac

    local issues_json
    issues_json=$( cd "$leader_repo" && glab "${list_args[@]}" 2>/dev/null )
    if [[ -z "$issues_json" || "$issues_json" == "null" || "$issues_json" == "[]" ]]; then
      printf '[qqq] no %s issues found in this project.\n' "$state_pick" >&2
      qqq_log_workflow_event "phase0_register_issue" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "mode" "pick" "reason" "no issues found"
      return 1
    fi

    # fzf rows: "<iid>\t#<iid> <title> [<state>]"; preview shows full description.
    local rows
    rows=$(printf '%s' "$issues_json" \
      | jq -r '.[] | "\(.iid)\t#\(.iid) \(.title) [\(.state)]"')
    if [[ -z "$rows" ]]; then
      printf '[qqq] failed to render issue list.\n' >&2
      return 1
    fi

    # Cache the issues JSON in a tmp file. The previous implementation
    # embedded the entire JSON into fzf's --preview argument verbatim, which
    # blew up with large `issue list` payloads (every keystroke re-passed
    # the full payload through argv, risking ARG_MAX). Now the preview
    # command reads the file by path.
    local issues_tmp
    issues_tmp=$(mktemp "${TMPDIR:-/tmp}/qqq-phase0-issues.XXXXXX") || return 1
    printf '%s' "$issues_json" >"$issues_tmp"
    # shellcheck disable=SC2064
    trap "rm -f $(printf '%q' "$issues_tmp")" RETURN

    local preview_cmd
    preview_cmd=$(printf 'jq -r --arg iid "{1}" '\''.[] | select(.iid == ($iid|tonumber)) | .description // "(no description)"'\'' %q' "$issues_tmp")
    local picked
    picked=$(printf '%s\n' "$rows" | qqq_fzf \
      --prompt='pick issue > ' --height=60% \
      --delimiter=$'\t' --with-nth=2 --accept-nth=1 \
      --preview "$preview_cmd" \
      --preview-window=right:55%,wrap) || {
      printf '[qqq] register-issue cancelled.\n' >&2
      return 1
    }
    iid="$picked"
    if [[ -z "$iid" ]]; then
      printf '[qqq] no issue selected.\n' >&2
      return 1
    fi

    # Extract chosen issue's metadata from the cached JSON.
    local issue_obj
    issue_obj=$(jq -c --arg iid "$iid" '.[] | select(.iid == ($iid|tonumber))' "$issues_tmp")
    title=$(printf '%s' "$issue_obj" | jq -r '.title // empty')
    description=$(printf '%s' "$issue_obj" | jq -r '.description // empty')
    state=$(printf '%s' "$issue_obj" | jq -r '.state // "opened"')
    web_url=$(printf '%s' "$issue_obj" | jq -r '.web_url // empty')
    labels_csv=$(printf '%s' "$issue_obj" | jq -r '(.labels // []) | join(",")')
    assignees_csv=$(printf '%s' "$issue_obj" | jq -r '(.assignees // []) | map(.username) | join(",")')
  fi

  # iid duplicate check (D10c) — warn but allow continue.
  local collisions
  collisions=$(qqq_phase0_iid_collisions "$iid" "$session_dir")
  if [[ -n "$collisions" ]]; then
    printf '[qqq] issue #%s already registered in another active session:\n' "$iid" >&2
    printf '%s\n' "$collisions" | sed 's/^/  - /' >&2
    local cont_reply
    qqq_read_prompt "[qqq] register here too? [y/N]: " cont_reply || return 1
    if [[ "$cont_reply" != [Yy]* ]]; then
      printf '[qqq] register-issue cancelled.\n' >&2
      qqq_log_workflow_event "phase0_register_issue" "error" "" "$session_dir" \
        "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
        "mode" "$mode" "iid" "$iid" "reason" "duplicate iid declined"
      return 1
    fi
  fi

  # Format YAML list inline (single-line); jq -c output is compact.
  local labels_yaml="[]" assignees_yaml="[]"
  if [[ -n "$labels_csv" ]]; then
    labels_yaml=$(printf '%s' "$labels_csv" | tr ',' '\n' | jq -R . | jq -sc .)
  fi
  if [[ -n "$assignees_csv" ]]; then
    assignees_yaml=$(printf '%s' "$assignees_csv" | tr ',' '\n' | jq -R . | jq -sc .)
  fi

  # Atomic write of phase0-issue.md.
  local out_path="$session_dir/phase0-issue.md"
  local tmp_path="$out_path.tmp.$$"
  {
    printf -- '---\n'
    printf 'iid: %s\n'           "$iid"
    printf 'web_url: %s\n'       "$web_url"
    printf 'state: %s\n'         "$state"
    printf 'labels: %s\n'        "$labels_yaml"
    printf 'assignees: %s\n'     "$assignees_yaml"
    printf 'source_action: %s\n' "$source_action"
    printf 'registered_at: %s\n' "$(qqq_iso_timestamp)"
    printf -- '---\n\n'
    printf '# %s\n\n' "$title"
    if [[ -n "$description" ]]; then
      printf '%s\n' "$description"
    else
      printf '(no description)\n'
    fi
  } >"$tmp_path" || { rm -f "$tmp_path"; return 1; }
  mv "$tmp_path" "$out_path"

  qqq_log_workflow_event "phase0_register_issue" "completed" "" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "mode" "$mode" \
    "iid" "$iid" \
    "source_action" "$source_action"

  printf '[qqq] phase0-issue.md written for issue #%s\n' "$iid" >&2
}
