# qqq lib — action-menu
# select_action picker, iteration count prompt, and input-guard helpers.
# These three sub-sections were adjacent in qqq-workflow.sh and are tightly
# coupled at the picker entry point (select_action drives all three).
# Loaded after phase-detect; consumes phase_title / phase_desc /
# phase_status_mark for menu rendering and session_preview from
# session-mgmt for the fzf preview pane.
source "$__qqq_lib_dir/phase-detect.sh"
# ---------------------------------------------------------------------------
# Action menu
# ---------------------------------------------------------------------------

select_action() {
  local sess="$1" suggested="$2"
  # Sessions can be in leader-mode (no worktree) or worktree-mode. Completed
  # (archived) sessions get a read-only menu.
  local leader_repo="" wt_root="" wt_state="" merge_status="" rebase_in_progress=no
  leader_repo=$(qqq_leader_repo_from "$sess" 2>/dev/null) \
    || leader_repo=$(qqq_leader_repo_from "$PWD" 2>/dev/null) \
    || leader_repo=""
  if [[ -n "$leader_repo" ]]; then
    wt_root=$(qqq_session_dir_worktree "$sess")
    local _wt_status_line
    _wt_status_line=$(qqq_session_worktree_status "$sess" "$leader_repo" 2>/dev/null) || _wt_status_line=""
    wt_state="${_wt_status_line##*$'\t'}"
    wt_state="${wt_state%$'\n'}"
    if [[ -n "$wt_root" ]] && qqq_worktree_rebase_in_progress "$wt_root"; then
      rebase_in_progress=yes
    fi
  fi
  merge_status=$(qqq_session_merge_display_status "$sess")

  local options=()
  if [[ "$sess" == */claude-works-completed/* && "$merge_status" == "completed" ]]; then
    options=(
      view-artifacts
      open-session-dir
    )
  elif [[ "$merge_status" == "push_pending" ]]; then
    options=(
      merge-resume-push
      view-artifacts
      open-session-dir
    )
  else
    options=(
      register-issue
      req-clarifier
      ui-outliner
      nltp-interviewer
      tech-interviewer
      code-planner
      code-implementer
      rewind
      view-artifacts
      open-session-dir
    )
    # Worktree actions are conditional on the worktree being live (or absent).
    if [[ "$wt_state" == "live" ]]; then
      options+=(worktree-open worktree-remove)
    else
      options+=(worktree-create)
    fi
    if [[ "$rebase_in_progress" == "yes" ]]; then
      options=(resolve-rebase-conflict "${options[@]}")
    fi
    # worktree-merge requires a live worktree (Stage 11 enforces this in
    # detect_next_phase too); keep the picker symmetric.
    if [[ -f "$sess/phase3-implement-log.md" && "$wt_state" == "live" ]]; then
      options+=(worktree-merge)
    fi
  fi

  # Leader-mode banner (M4): only when no worktree and no active recovery state.
  local leader_mode_banner=""
  if [[ -z "$wt_root" && -z "$merge_status" ]]; then
    leader_mode_banner="no worktree — code changes touch leader directly · pick worktree-create when ready"$'\n'
  fi

  # Build a "last run: ..." header line from .qqq/agent-<role>.{start,exit}.
  # Picks the most recently launched agent and reports its outcome.
  local last_role="" last_status="" last_extra="" last_run_line=""
  if [[ -d "$sess/.qqq" ]]; then
    local newest="" f
    for f in "$sess"/.qqq/agent-*.start; do
      [[ -f "$f" ]] || continue
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
        newest="$f"
      fi
    done
    if [[ -n "$newest" ]]; then
      last_role=$(basename "$newest" .start)
      last_role="${last_role#agent-}"
      local last_exit_file="$sess/.qqq/agent-${last_role}.exit"
      if [[ -f "$last_exit_file" && "$last_exit_file" -nt "$newest" ]]; then
        local last_line last_code last_at
        last_line=$(head -n 1 "$last_exit_file" 2>/dev/null)
        last_code="${last_line%%$'\t'*}"
        last_at="${last_line#*$'\t'}"
        if [[ "$last_code" == "0" ]]; then
          last_status="ok"
        else
          last_status="ERR"
        fi
        last_extra="exit=${last_code} at ${last_at}"
      else
        last_status="..."
        last_extra="running or aborted"
      fi
      last_run_line=$'\n'"last run: [${last_status}] ${last_role} · ${last_extra}"
    fi
  fi

  local picked
  local preview_cmd
  printf -v preview_cmd "bash -c 'session_preview \"\$1\"' _ %q" "$sess"
  picked=$(
    {
      local opt mark title desc title_line desc_line
      local esc=$'\033'
      for opt in "${options[@]}"; do
        mark=$(phase_status_mark "$sess" "$opt" "$suggested")
        title=$(phase_title "$opt")
        desc=$(phase_desc "$opt")
        title_line="${esc}[1m[${mark}] ${title}${esc}[0m"
        desc_line="    ${esc}[2mabout: ${desc}${esc}[0m"
        printf '%s|%s\n%s\0' "$opt" "$title_line" "$desc_line"
      done
    } | qqq_fzf --read0 --ansi \
          --delimiter='|' --with-nth=2.. --accept-nth=1 \
          --prompt="next > " \
          --header="${leader_mode_banner}"$'Enter to run · Esc/Ctrl-C to change session\n[★] suggested   [●] done   [ ] available\n'"session: $(basename "$sess")   ·   suggested: ${suggested}${last_run_line}" \
          --height=80% \
          --gap=1 \
          --wrap=word \
          --preview "$preview_cmd" \
          --preview-label=' session ' \
          --preview-window=up:40%,wrap,border-bottom
  ) || return 1
  printf '%s' "$picked"
}

# ---------------------------------------------------------------------------
# Iteration prompt (for code-planner / code-implementer)
# ---------------------------------------------------------------------------

prompt_iterations() {
  local raw
  qqq_read_prompt "[qqq] iterations [$DEFAULT_ITERATIONS]: " raw || return 1
  raw="${raw:-$DEFAULT_ITERATIONS}"
  # 10#$raw forces decimal so inputs like "09" don't trigger bash's octal parser.
  if ! [[ "$raw" =~ ^[0-9]+$ ]] || (( 10#$raw < 1 )); then
    printf '[qqq] invalid iteration value; using default %d\n' "$DEFAULT_ITERATIONS" >&2
    raw="$DEFAULT_ITERATIONS"
  fi
  printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# Input guards
# ---------------------------------------------------------------------------

guard_file() {
  local label="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    printf '[qqq] missing input for this phase (%s): %s\n' "$label" "$path" >&2
    printf '[qqq] run the prior phase first.\n' >&2
    return 1
  fi
  return 0
}

