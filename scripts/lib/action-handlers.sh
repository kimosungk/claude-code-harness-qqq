# qqq lib — action-handlers
# Action dispatch layer: run_agent (the universal Claude agent launcher
# with deny-list permission model + Phase 0 inject), launch_rebase_conflict_
# resolver, and the tmux-side helpers run by repository-action menu items
# (rewind_session, view_artifacts, open_session_dir).
# Loaded after tmux-launch; consumes launch_in_tmux_window plus the agent-
# window preflight pipeline, agent-launch-cwd resolution from worktree-
# helpers, and the PR3 deny list shared with launch_rebase_conflict_resolver.
source "$__qqq_lib_dir/tmux-launch.sh"
# ---------------------------------------------------------------------------
# Action handlers
# ---------------------------------------------------------------------------

# PR3 deny list — the single source of truth for `claude --disallowedTools`.
# bypassPermissions overrides allow rules, so per-agent allowedTools is dead
# code; deny rules win in every mode, hence a narrow shared deny list of
# high-blast-radius operations only. Phase agents that need MCP / WebSearch
# / Write / Task get them via their agent frontmatter `tools:` declaration.
# Notable exclusions: curl, kill, rm -f (no -r) — ui-verifier needs them to
# clean up its dev server. Both run_agent and launch_rebase_conflict_resolver
# pass `$(qqq_disallowed_tools)` to claude so they cannot drift.
qqq_disallowed_tools() {
  printf '%s' "NotebookEdit,Bash(git push *),Bash(git reset --hard *),Bash(git clean *),Bash(git branch -D *),Bash(git worktree remove *),Bash(rm -rf *),Bash(sudo *),Bash(chown *),Bash(chmod -R *)"
}

run_agent() {
  local sess="$1" agent="$2" injected="${3:-}" prompt_iter="${4:-0}"
  printf '[qqq] action: %s  ·  session: %s\n' "$agent" "$(basename "$sess")" >&2
  local preflight_decision
  preflight_decision=$(qqq_agent_window_preflight "$sess" "$agent") || return 1
  case "$preflight_decision" in
    focus-existing|cancel)
      return 0
      ;;
  esac
  local extra=""
  if [[ "$prompt_iter" == "1" ]]; then
    local iter
    iter=$(prompt_iterations) || return 1
    extra="iterations=$iter"
  fi
  # Track agent run state so the picker/menu can show ✓/✗/… markers.
  mkdir -p "$sess/.qqq" 2>/dev/null
  date -Iseconds > "$sess/.qqq/agent-${agent}.start" 2>/dev/null
  rm -f "$sess/.qqq/agent-${agent}.exit" 2>/dev/null
  local dev_branch
  dev_branch=$(qqq_origin_dev_branch)
  # Launch from the launch-relative cwd in the active checkout so shell commands
  # target the same repo slice where the session artifacts live.
  local launch_cwd
  launch_cwd=$(qqq_agent_launch_cwd_for_session "$sess")
  # Plugin-namespaced agent id (claude CLI expects the fully-qualified name).
  local agent_id="qqq:${agent}"
  local disallowed_tools
  disallowed_tools=$(qqq_disallowed_tools)
  local qqq_plugin_dir
  qqq_plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local qqq_skill_root="$qqq_plugin_dir/skills"
  local qqq_agent_root="$qqq_plugin_dir/agents"

  # Phase 0 injection: when launching req-clarifier and phase0-issue.md exists,
  # pass it as the agent's system-prompt context via --append-system-prompt-file
  # (file ref avoids argv size limits and shell-escapes the issue body cleanly).
  local phase0_inject_part=""
  if [[ "$agent" == "req-clarifier" ]]; then
    if [[ -f "$sess/phase0-issue.md" ]]; then
      phase0_inject_part="--append-system-prompt-file $(printf '%q' "$sess/phase0-issue.md") "
    else
      printf '[qqq] phase0-issue.md not found — describe the issue directly to the agent after launch.\n' >&2
    fi
  fi

  local cmd
  printf -v cmd "cd %q && export QQQ_AGENT=%q QQQ_SESSION_DIR=%q QQQ_PHASE=%q QQQ_DEV_BRANCH=%q QQQ_PLUGIN_DIR=%q QQQ_SKILL_ROOT=%q QQQ_AGENT_ROOT=%q && claude --permission-mode bypassPermissions --disallowedTools %q --agent %q" \
    "$launch_cwd" "$agent" "$sess" "$agent" "$dev_branch" "$qqq_plugin_dir" "$qqq_skill_root" "$qqq_agent_root" "$disallowed_tools" "$agent_id"
  # Splice the phase0 flag between --disallowedTools and --agent. There is
  # exactly one `--agent ` token in cmd so this substitution is unambiguous.
  if [[ -n "$phase0_inject_part" ]]; then
    cmd="${cmd//--agent /${phase0_inject_part}--agent }"
  fi
  if [[ -n "$injected" && -n "$extra" ]]; then
    cmd+=" '@${injected} ${extra}'"
  elif [[ -n "$injected" ]]; then
    cmd+=" '@${injected}'"
  fi
  printf '[qqq] launching %s in tmux window...\n' "$agent"
  qqq_log_workflow_event "agent_launch" "started" "$agent" "$sess" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "dev_branch" "$dev_branch"
  local win_slug
  win_slug=$(qqq_window_slug_from_session_dir "$sess")
  local focus_policy="menu"
  case "$agent" in
    req-clarifier|ui-outliner|nltp-interviewer|tech-interviewer)
      # Interactive interview agents — jump straight to the agent window so
      # the user can see and respond to the prompt immediately.
      focus_policy="target"
      ;;
  esac
  local exit_file="$sess/.qqq/agent-${agent}.exit"
  launch_in_tmux_window "${win_slug}:${agent}" "$cmd" "$focus_policy" "$exit_file"
}

launch_rebase_conflict_resolver() {
  local session_dir="$1" wt_path="$2" dev_branch="$3"
  local preflight_decision
  preflight_decision=$(qqq_agent_window_preflight "$session_dir" "rebase-resolver") || return 1
  case "$preflight_decision" in
    focus-existing|cancel)
      return 0
      ;;
  esac
  local slug win_name plan args cmd disallowed_tools launch_cwd leader_repo
  slug=$(qqq_window_slug_from_session_dir "$session_dir")
  win_name="${slug}:rebase-resolver"
  disallowed_tools=$(qqq_disallowed_tools)
  plan="$session_dir/phase2-code-plan.md"
  leader_repo=$(qqq_leader_repo_from "$wt_path" 2>/dev/null || printf '%s' "$wt_path")
  launch_cwd=$(qqq_checkout_exec_cwd "$wt_path" "$leader_repo")
  if [[ -f "$plan" ]]; then
    args="$plan worktree=$wt_path dev_branch=$dev_branch"
  else
    args="$session_dir worktree=$wt_path dev_branch=$dev_branch"
  fi
  printf -v cmd "cd %q && export QQQ_AGENT=%q QQQ_SESSION_DIR=%q QQQ_PHASE=%q QQQ_DEV_BRANCH=%q && claude --permission-mode bypassPermissions --disallowedTools %q --agent qqq:rebase-conflict-resolver %q" \
    "$launch_cwd" "rebase-conflict-resolver" "$session_dir" "resolve-rebase-conflict" "$dev_branch" "$disallowed_tools" "$args"
  printf '[qqq] launching rebase-conflict-resolver in tmux window...\n'
  qqq_log_workflow_event "agent_launch" "started" "rebase-conflict-resolver" "$session_dir" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "worktree_path" "$wt_path" \
    "dev_branch" "$dev_branch"
  launch_in_tmux_window "$win_name" "$cmd"
}

rewind_session() {
  local sess="$1"
  # Warn about running agent windows — rewind removes artifacts but does NOT kill tmux windows,
  # so an active agent can re-create files after they're deleted.
  if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    local entries agent_windows="" index role name
    entries=$(qqq_list_session_agent_windows "$sess")
    while IFS=$'\t' read -r index role name; do
      [[ -n "$name" ]] || continue
      agent_windows+="${name}"$'\n'
    done <<<"$entries"
    if [[ -n "$agent_windows" ]]; then
      printf '[qqq] warning: these agent tmux windows are still open:\n'
      printf '%s' "$agent_windows" | sed 's/^/  - /'
      printf '[qqq] close them first (Ctrl-b & in the window) or the agent may re-create deleted files.\n\n'
    fi
  fi

  local phase_pick
  phase_pick=$({
      printf 'phase1 (redo from scratch — deletes phase1 + phase2 + phase3)\n'
      printf 'phase2 (redo plan — deletes phase2 + phase3)\n'
      printf 'phase3 (redo implement — deletes phase3 only)\n'
      printf 'cancel\n'
  } | qqq_fzf --prompt='rewind to > ' --height=40%) || { printf '[qqq] cancelled.\n'; return 0; }

  local rewind_to
  case "$phase_pick" in
    phase1*) rewind_to=1 ;;
    phase2*) rewind_to=2 ;;
    phase3*) rewind_to=3 ;;
    *)       printf '[qqq] cancelled.\n'; return 0 ;;
  esac

  local targets=()
  if (( rewind_to <= 1 )); then
    targets+=(phase1-spec.md phase1-ui-outline.md phase1-ui-outline.html phase1-nltp.md)
    local f
    for f in "$sess"/phase1-nltp-review-*.md; do
      [[ -f "$f" ]] && targets+=("$(basename "$f")")
    done
  fi
  if (( rewind_to <= 2 )); then
    targets+=(phase1-tech-spec.md)
    targets+=(phase2-code-plan.md phase2-review-log.md)
    targets+=(phase2-review-state.json)
    local f
    for f in "$sess"/phase2-review-round-*.md \
             "$sess"/phase2-g1-explorer-*.md \
             "$sess"/phase2-g2-architect-*.md \
             "$sess"/phase2-g3-critic-*.md \
             "$sess"/phase2-codex-review-*.md \
             "$sess"/phase2-claude-review-*.md; do
      [[ -f "$f" ]] && targets+=("$(basename "$f")")
    done
  fi
  if (( rewind_to <= 3 )); then
    targets+=(phase3-implement-log.md)
    local f
    for f in "$sess"/phase3-codex-review-*.md \
             "$sess"/phase3-claude-review-*.md; do
      [[ -f "$f" ]] && targets+=("$(basename "$f")")
    done
  fi

  local existing=()
  local t
  for t in "${targets[@]}"; do
    [[ -f "$sess/$t" ]] && existing+=("$t")
  done

  if (( ${#existing[@]} == 0 )); then
    printf '[qqq] nothing to rewind at phase%d+.\n' "$rewind_to"
    return 0
  fi

  printf '[qqq] rewind to phase%d will delete these files in %s:\n' "$rewind_to" "$(basename "$sess")"
  printf '  - %s\n' "${existing[@]}"
  local confirm
  qqq_read_prompt "[qqq] proceed? type 'yes' to confirm: " confirm || return 1
  if [[ "$confirm" != "yes" ]]; then
    printf '[qqq] cancelled.\n'
    return 0
  fi
  for t in "${existing[@]}"; do
    rm -f "$sess/$t"
  done
  printf '[qqq] removed %d file(s).\n' "${#existing[@]}"
}

view_artifacts() {
  local sess="$1"
  ensure_tmux_session
  if window_exists "menu"; then
    tmux split-window -d -t "$TMUX_SESSION_NAME:menu" -h "cd '$sess' && ls -la && exec $SHELL"
    # Make the split available without stealing focus from the menu pane.
    select_menu_window
    attach_if_outside
  else
    # menu window was closed — fall back to a dedicated window.
    launch_in_tmux_window "$(qqq_window_slug_from_session_dir "$sess"):view-artifacts" "cd '$sess' && ls -la"
  fi
}

open_session_dir() {
  local sess="$1"
  launch_in_tmux_window "$(qqq_window_slug_from_session_dir "$sess"):shell" "cd '$sess' && exec $SHELL"
}

