# qqq lib — tmux-launch
# tmux session/window orchestration: ensure_tmux_session, window_exists,
# attach_if_outside, the tmux_menu_hint return-to-menu helper, the
# per-session agent-window inventory (qqq_list_session_agent_windows et al),
# the duplicate/non-duplicate preflight prompt, and launch_in_tmux_window
# (the universal "run a command in a kept-open tmux window" entry point).
# Loaded after action-menu; itself depends on bootstrap exports
# (TMUX_SESSION_NAME, qqq_read_prompt) and the agent-role registry from
# session-mgmt (qqq_is_managed_agent_role, qqq_log_workflow_event,
# qqq_window_slug_from_session_dir).
source "$__qqq_lib_dir/action-menu.sh"
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

