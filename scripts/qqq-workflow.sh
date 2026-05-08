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

# ---------------------------------------------------------------------------
# tmux launch
# ---------------------------------------------------------------------------

ensure_tmux_session() {
  local menu_cmd
  printf -v menu_cmd "clear; printf '[qqq] persistent menu window for %q\\n'; printf '[qqq] qqq returns focus here after each action.\\n'; printf '[qqq] switch to another tmux window when you want to inspect output.\\n'; while :; do sleep 3600; done" \
    "$TMUX_SESSION_NAME"
  if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION_NAME" -n "menu" "$menu_cmd"
    return
  fi
  if ! window_exists "menu"; then
    tmux new-window -d -t "$TMUX_SESSION_NAME:" -n "menu" "$menu_cmd"
  fi
}

window_exists() {
  local win_name="$1"
  # -F treats the pattern as a fixed string so regex metacharacters are inert.
  tmux list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' 2>/dev/null \
    | grep -qxF "$win_name"
}

attach_if_outside() {
  if [[ -n "${TMUX:-}" ]]; then
    return 0
  fi
  tmux attach -t "$TMUX_SESSION_NAME"
}

tmux_menu_hint() {
  local idx
  idx=$(tmux list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_name}\t#{window_index}' 2>/dev/null \
    | awk -F'\t' '$1=="menu" { print $2; exit }')
  if [[ -n "$idx" ]]; then
    printf 'return to menu: Ctrl-b %s (window: menu)' "$idx"
  else
    printf 'return to menu: select tmux window "menu"'
  fi
}

select_menu_window() {
  if window_exists "menu"; then
    tmux select-window -t "$TMUX_SESSION_NAME:menu"
  fi
}

qqq_list_session_agent_windows() {
  local sess="$1"
  tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null || return 0
  local win_slug prefix entry index name role
  win_slug=$(qqq_window_slug_from_session_dir "$sess")
  prefix="${win_slug}:"
  while IFS=$'\t' read -r index name; do
    [[ -n "$index" && -n "$name" ]] || continue
    [[ "$name" == "$prefix"* ]] || continue
    role="${name#"$prefix"}"
    qqq_is_managed_agent_role "$role" || continue
    printf '%s\t%s\t%s\n' "$index" "$role" "$name"
  done < <(tmux list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_index}\t#{window_name}' 2>/dev/null)
}

qqq_format_agent_window_matches() {
  local entries="$1"
  local out="" index role name
  while IFS=$'\t' read -r index role name; do
    [[ -n "$index" && -n "$name" ]] || continue
    [[ -n "$out" ]] && out+=","
    out+="${index}:${name}"
  done <<<"$entries"
  printf '%s' "$out"
}

qqq_print_session_agent_windows() {
  local entries="$1"
  local index role name
  while IFS=$'\t' read -r index role name; do
    [[ -n "$index" && -n "$name" ]] || continue
    printf '  - [%s] %s\n' "$index" "$name"
  done <<<"$entries"
}

qqq_highest_agent_window_index_for_role() {
  local sess="$1" target_role="$2"
  local entries index role name highest=""
  entries=$(qqq_list_session_agent_windows "$sess")
  while IFS=$'\t' read -r index role name; do
    [[ "$role" == "$target_role" ]] || continue
    if [[ -z "$highest" || "$index" -gt "$highest" ]]; then
      highest="$index"
    fi
  done <<<"$entries"
  [[ -n "$highest" ]] && printf '%s' "$highest"
}

qqq_kill_tmux_windows_by_index() {
  local sorted_indexes=()
  local index
  if (( $# == 0 )); then
    return 0
  fi
  while IFS= read -r index; do
    [[ -n "$index" ]] || continue
    sorted_indexes+=("$index")
  done < <(printf '%s\n' "$@" | awk 'NF' | sort -rn)
  for index in "${sorted_indexes[@]}"; do
    [[ -n "$index" ]] || continue
    tmux kill-window -t "$TMUX_SESSION_NAME:$index"
  done
}

qqq_kill_session_agent_windows_by_role() {
  local sess="$1" target_role="$2"
  local entries index role name indexes=()
  entries=$(qqq_list_session_agent_windows "$sess")
  while IFS=$'\t' read -r index role name; do
    [[ "$role" == "$target_role" ]] || continue
    indexes+=("$index")
  done <<<"$entries"
  (( ${#indexes[@]} > 0 )) && qqq_kill_tmux_windows_by_index "${indexes[@]}"
}

qqq_kill_session_agent_windows() {
  local sess="$1"
  local entries index role name indexes=()
  entries=$(qqq_list_session_agent_windows "$sess")
  while IFS=$'\t' read -r index role name; do
    [[ -n "$index" ]] || continue
    indexes+=("$index")
  done <<<"$entries"
  (( ${#indexes[@]} > 0 )) && qqq_kill_tmux_windows_by_index "${indexes[@]}"
}

qqq_focus_session_agent_window() {
  local sess="$1" target_role="$2"
  local index
  index=$(qqq_highest_agent_window_index_for_role "$sess" "$target_role")
  [[ -n "$index" ]] || return 1
  tmux select-window -t "$TMUX_SESSION_NAME:$index"
  attach_if_outside
}

qqq_agent_window_conflict_action_for_log() {
  case "$1" in
    focus-existing) printf 'focus' ;;
    kill-same-role-and-launch) printf 'kill_same_role_and_launch' ;;
    kill-all-and-launch) printf 'kill_all_and_launch' ;;
    launch) printf 'launch' ;;
    cancel) printf 'cancel' ;;
    *) printf '%s' "$1" ;;
  esac
}

qqq_prompt_agent_window_preflight() {
  local sess="$1" target_role="$2" mode="$3" entries="$4"
  local choice=""
  printf '[qqq] existing agent tmux windows for %s:\n' "$(basename "$sess")" >&2
  qqq_print_session_agent_windows "$entries" >&2
  case "$mode" in
    duplicate)
      printf '[qqq] %s already has an open window in this session.\n' "$target_role" >&2
      printf '  1. Focus the existing %s window\n' "$target_role" >&2
      printf '  2. Kill the existing %s window(s) and launch a new one\n' "$target_role" >&2
      printf '  3. Cancel\n' >&2
      while :; do
        qqq_read_prompt "[qqq] select [1/2/3]: " choice || return 1
        case "$choice" in
          1|f|F) printf 'focus-existing'; return 0 ;;
          2|r|R) printf 'kill-same-role-and-launch'; return 0 ;;
          3|c|C) printf 'cancel'; return 0 ;;
        esac
        printf '[qqq] invalid selection: %s\n' "$choice" >&2
      done
      ;;
    non_duplicate)
      printf '[qqq] another agent window is already open for this session.\n' >&2
      printf '  1. Kill all existing agent windows for this session and launch a new %s window\n' "$target_role" >&2
      printf '  2. Launch a new %s window and keep the existing ones\n' "$target_role" >&2
      printf '  3. Cancel\n' >&2
      while :; do
        qqq_read_prompt "[qqq] select [1/2/3]: " choice || return 1
        case "$choice" in
          1|k|K) printf 'kill-all-and-launch'; return 0 ;;
          2|n|N) printf 'launch'; return 0 ;;
          3|c|C) printf 'cancel'; return 0 ;;
        esac
        printf '[qqq] invalid selection: %s\n' "$choice" >&2
      done
      ;;
  esac
}

qqq_agent_window_preflight() {
  local sess="$1" target_role="$2"
  local entries same_role_entries="" index role name mode="none" decision="launch" matched_windows=""
  entries=$(qqq_list_session_agent_windows "$sess")
  if [[ -n "$entries" ]]; then
    while IFS=$'\t' read -r index role name; do
      [[ "$role" == "$target_role" ]] || continue
      same_role_entries+="${index}"$'\t'"${role}"$'\t'"${name}"$'\n'
    done <<<"$entries"
    if [[ -n "$same_role_entries" ]]; then
      mode="duplicate"
      decision=$(qqq_prompt_agent_window_preflight "$sess" "$target_role" "$mode" "$same_role_entries") || return 1
      matched_windows=$(qqq_format_agent_window_matches "$same_role_entries")
    else
      mode="non_duplicate"
      decision=$(qqq_prompt_agent_window_preflight "$sess" "$target_role" "$mode" "$entries") || return 1
      matched_windows=$(qqq_format_agent_window_matches "$entries")
    fi
  fi

  case "$decision" in
    focus-existing)
      qqq_focus_session_agent_window "$sess" "$target_role" || return 1
      ;;
    kill-same-role-and-launch)
      qqq_kill_session_agent_windows_by_role "$sess" "$target_role"
      ;;
    kill-all-and-launch)
      qqq_kill_session_agent_windows "$sess"
      ;;
  esac

  qqq_log_workflow_event "agent_window_conflict" "handled" "$target_role" "$sess" \
    "schema_version" "$QQQ_LOG_SCHEMA_VERSION" \
    "target_role" "$target_role" \
    "mode" "$mode" \
    "action" "$(qqq_agent_window_conflict_action_for_log "$decision")" \
    "matched_windows" "$matched_windows"
  printf '%s' "$decision"
}

launch_in_tmux_window() {
  local win_name="$1"
  local shell_cmd="$2"
  local focus_policy="${3:-menu}"
  local exit_file="${4:-}"
  ensure_tmux_session
  local menu_hint hint_quoted wrapped_cmd
  menu_hint=$(tmux_menu_hint)
  printf -v hint_quoted '%q' "$menu_hint"
  if [[ -n "$exit_file" ]]; then
    local exit_file_quoted
    printf -v exit_file_quoted '%q' "$exit_file"
    wrapped_cmd="printf '%s\\n\\n' $hint_quoted; $shell_cmd; rc=\$?; printf '%s\\t%s\\n' \"\$rc\" \"\$(date -Iseconds)\" > $exit_file_quoted 2>/dev/null; printf '\\n[qqq] window kept open. Type exit to close.\\n'; exec $SHELL"
  else
    wrapped_cmd="printf '%s\\n\\n' $hint_quoted; $shell_cmd; printf '\\n[qqq] window kept open. Type exit to close.\\n'; exec $SHELL"
  fi
  if window_exists "$win_name"; then
    local current_cmd
    current_cmd=$(tmux display-message -p -t "$TMUX_SESSION_NAME:$win_name" '#{pane_current_command}' 2>/dev/null || printf '')
    case "$current_cmd" in
      bash|zsh|fish|sh|dash|ksh)
        # Idle shell after a prior agent exited — safe to re-run the command.
        printf '[qqq] window "%s" exists with idle %s — re-injecting command.\n' "$win_name" "$current_cmd"
        tmux send-keys -t "$TMUX_SESSION_NAME:$win_name" "$wrapped_cmd" C-m
        ;;
      *)
        # Something non-shell is running (claude, editor, etc.) — just focus, do not disturb.
        printf '[qqq] window "%s" is busy (%s active) — selecting only. Let it finish (or Ctrl-b & to close) before re-running.\n' \
          "$win_name" "${current_cmd:-unknown}"
        ;;
    esac
  else
    tmux new-window -t "$TMUX_SESSION_NAME:" -n "$win_name" \
      "$wrapped_cmd"
  fi
  case "$focus_policy" in
    menu)
      select_menu_window
      ;;
    target)
      tmux select-window -t "$TMUX_SESSION_NAME:$win_name"
      ;;
  esac
  attach_if_outside
}

# ---------------------------------------------------------------------------
# Action handlers
# ---------------------------------------------------------------------------

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
  # Permission model: bypassPermissions overrides --allowedTools (allow rules
  # are advisory under bypass), so the previous per-agent allowedTools
  # whitelist was dead code. Deny rules, however, win in every mode — so we
  # only ship a narrow shared deny list for high-blast-radius operations.
  # Phase agents that need MCP/WebSearch/Write/Task get them automatically
  # via their agent frontmatter `tools:` declaration; nothing per-agent here.
  local disallowed_tools
  disallowed_tools="NotebookEdit,Bash(git push *),Bash(git reset --hard *),Bash(git clean *),Bash(git branch -D *),Bash(git worktree remove *),Bash(rm -rf *),Bash(sudo *),Bash(chown *),Bash(chmod -R *)"
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
  # See run_agent for the deny-only rationale.
  disallowed_tools="NotebookEdit,Bash(git push *),Bash(git reset --hard *),Bash(git clean *),Bash(git branch -D *),Bash(git worktree remove *),Bash(rm -rf *),Bash(sudo *),Bash(chown *),Bash(chmod -R *)"
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

# ---------------------------------------------------------------------------
# Merge-time artifact commit (Stage 4)
# ---------------------------------------------------------------------------

# Commit only the active session artifact tree in the given worktree.
# Excludes .qqq.lock via pathspec. Idempotent — no-op when nothing changed.
# Returns 0 on skip or success; stderr for status lines only.
commit_session_artifacts_if_dirty() {
  local worktree="$1" session_dir="$2"
  [[ -d "$worktree" && -d "$session_dir" ]] || return 0
  local rel="${session_dir#"$worktree"/}"
  # Guard: session_dir must actually be under worktree.
  [[ "$rel" == "$session_dir" ]] && return 0

  # Nothing tracked-changed AND nothing new — skip.
  if git -C "$worktree" diff --quiet HEAD -- "$rel" 2>/dev/null \
     && [[ -z $(git -C "$worktree" ls-files --others --exclude-standard -- "$rel" 2>/dev/null) ]]; then
    return 0
  fi

  git -C "$worktree" add -- "$rel" ":!$rel/.qqq.lock" >/dev/null 2>&1 || true

  # If staging the pathspec yielded nothing (e.g. only .qqq.lock changed), bail.
  if git -C "$worktree" diff --cached --quiet -- "$rel" 2>/dev/null; then
    return 0
  fi

  local slug
  slug=$(qqq_slug_from_session_dir "$session_dir")
  if git -C "$worktree" commit --no-verify -m "qqq: $slug archive session artifacts" >/dev/null; then
    printf '[qqq] auto-committed session artifacts under %s\n' "$rel" >&2
  fi
}

# Rename session dir from <worktree>/<launch-subdir>/claude-works/<date_slug>/ to
# <worktree>/<launch-subdir>/claude-works-completed/<date_slug>/ with a dedicated commit.
# Emits new absolute path on stdout when the move succeeds; empty otherwise.
# Fails fast when the destination already exists.
archive_session_to_completed() {
  local worktree="$1" session_dir="$2"
  [[ -d "$worktree" && -d "$session_dir" ]] || return 0
  local rel_src="${session_dir#"$worktree"/}"
  [[ "$rel_src" == "$session_dir" ]] && return 0  # not inside worktree

  local base slug dest_rel dest_abs rel_parent prefix
  local merge_state_src merge_state_dest merge_state_tmp=""
  local moved_to_dest=no
  base=$(basename "$session_dir")
  slug=$(qqq_slug_from_session_dir "$session_dir")
  rel_parent=$(dirname "$rel_src")
  if [[ "$rel_parent" == "claude-works" ]]; then
    prefix=""
  elif [[ "$rel_parent" == */claude-works ]]; then
    prefix="${rel_parent%/claude-works}"
  else
    printf '[qqq] archive source is not under a claude-works/ tree: %s\n' "$rel_src" >&2
    return 1
  fi
  dest_rel="$(qqq_path_join "$prefix" "claude-works-completed/$base")"
  dest_abs="$worktree/$dest_rel"
  merge_state_src="$session_dir/.qqq/merge-state.json"
  merge_state_dest="$dest_abs/.qqq/merge-state.json"

  # Drop the runtime lock file so the source dir has no untracked leftovers
  # (git mv would otherwise leave .qqq.lock behind in the now-empty source).
  # The lock itself stays held via fd 9 against the inode.
  rm -f "$session_dir/.qqq.lock" 2>/dev/null || true
  if [[ -f "$merge_state_src" ]]; then
    merge_state_tmp=$(mktemp "${TMPDIR:-/tmp}/qqq-merge-state.XXXXXX") || return 1
    if ! mv "$merge_state_src" "$merge_state_tmp" 2>/dev/null; then
      rm -f "$merge_state_tmp" 2>/dev/null || true
      printf '[qqq] failed to preserve merge-state sidecar before archive.\n' >&2
      return 1
    fi
  fi

  mkdir -p "$(dirname "$dest_abs")"

  if [[ -e "$dest_abs" ]]; then
    printf '[qqq] completed archive already exists: %s\n' "$dest_abs" >&2
    printf '[qqq] keep the existing archive, clean it up manually, or change the session slug before retrying.\n' >&2
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      mkdir -p "$(dirname "$merge_state_src")"
      mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
    fi
    return 1
  fi

  if ! git -C "$worktree" mv "$rel_src" "$dest_rel" 2>/dev/null; then
    # Fallback: plain mv + add (source may have had untracked residue).
    if ! mv "$session_dir" "$dest_abs" 2>/dev/null; then
      if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
        mkdir -p "$(dirname "$merge_state_src")"
        mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
      fi
      printf '[qqq] archive mv failed (src=%s, dst=%s)\n' "$session_dir" "$dest_abs" >&2
      return 1
    fi
  fi
  moved_to_dest=yes
  git -C "$worktree" add -A -- "$rel_src" 2>/dev/null || true
  git -C "$worktree" add -- "$dest_rel" 2>/dev/null || true

  if git -C "$worktree" diff --cached --quiet 2>/dev/null; then
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      if [[ -d "$dest_abs" ]]; then
        mkdir -p "$(dirname "$merge_state_dest")"
        mv "$merge_state_tmp" "$merge_state_dest" 2>/dev/null || true
      else
        mkdir -p "$(dirname "$merge_state_src")"
        mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
      fi
    fi
    return 0  # nothing staged — caller treats as no-op, no new path emitted
  fi

  if ! git -C "$worktree" commit --no-verify -m "qqq: $slug archive to completed" >/dev/null; then
    if [[ "$moved_to_dest" == "yes" && -d "$dest_abs" && ! -e "$session_dir" ]]; then
      mkdir -p "$(dirname "$session_dir")"
      mv "$dest_abs" "$session_dir" 2>/dev/null || true
      git -C "$worktree" add -A -- "$rel_src" 2>/dev/null || true
      git -C "$worktree" add -A -- "$dest_rel" 2>/dev/null || true
    fi
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      mkdir -p "$(dirname "$merge_state_src")"
      mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
    fi
    printf '[qqq] archive commit failed.\n' >&2
    return 1
  fi
  if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
    mkdir -p "$(dirname "$merge_state_dest")"
    mv "$merge_state_tmp" "$merge_state_dest" 2>/dev/null || true
  fi
  printf '[qqq] archived session to %s\n' "$dest_rel" >&2
  printf '%s' "$dest_abs"
}

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
