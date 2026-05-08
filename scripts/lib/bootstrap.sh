# qqq lib — bootstrap
# Loaded by scripts/qqq-workflow.sh after the entry script enforces shell
# requirements. Owns shared environment defaults, dependency probes, the
# fzf/prompt test-injection layer, the nested-tmux guard, and the per-session
# flock primitives. No state outside the qqq namespace.

export LC_ALL="${LC_ALL:-C.UTF-8}"

# TMUX_SESSION_NAME is set in main() as "qqq|<repo-slug>" for per-repo isolation.
# The separator is "|" (not ":"): tmux parses -t target as "session:window.pane",
# so a colon inside the session name breaks every target lookup.
export TMUX_SESSION_NAME=""
readonly DEFAULT_ITERATIONS=3
readonly QQQ_LOG_SCHEMA_VERSION="1"

QQQ_WORKS_DIR="${QQQ_WORKS_DIR:-$PWD/claude-works}"
QQQ_COMPLETED_DIR="${QQQ_COMPLETED_DIR:-$(dirname "$QQQ_WORKS_DIR")/claude-works-completed}"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[qqq] required command not found: %s\n' "$1" >&2
    exit 1
  }
}

check_deps() {
  need claude
  need fzf
  need tmux
  need flock
  need git
  if ! command -v codex >/dev/null 2>&1; then
    printf '[qqq] warning: `codex` not found on PATH — reviewer flows will use Claude fallback instead of Codex-first review.\n' >&2
  fi
  if ! command -v glab >/dev/null 2>&1; then
    printf '[qqq] warning: `glab` not found on PATH — GitLab MR actions will be unavailable.\n' >&2
  fi
}

qqq_test_queue_pop() {
  local queue_file="${1:-}"
  [[ -n "$queue_file" && -f "$queue_file" ]] || return 1
  local line
  line=$(head -n 1 "$queue_file" 2>/dev/null) || return 1
  tail -n +2 "$queue_file" >"${queue_file}.tmp.$$" 2>/dev/null || : >"${queue_file}.tmp.$$"
  mv "${queue_file}.tmp.$$" "$queue_file"
  printf '%s' "$line"
}

qqq_fzf() {
  if [[ -n "${QQQ_TEST_FZF_QUEUE_FILE:-}" ]]; then
    if [[ ! -t 0 ]]; then
      if [[ -n "${QQQ_TEST_FZF_CAPTURE_FILE:-}" ]]; then
        cat >"$QQQ_TEST_FZF_CAPTURE_FILE"
      else
        cat >/dev/null
      fi
    fi
    qqq_test_queue_pop "$QQQ_TEST_FZF_QUEUE_FILE"
    return $?
  fi
  command fzf "$@"
}

qqq_read_prompt() {
  local prompt="$1" dest_var="$2"
  local value=""
  if [[ -n "${QQQ_TEST_PROMPT_QUEUE_FILE:-}" ]]; then
    value=$(qqq_test_queue_pop "$QQQ_TEST_PROMPT_QUEUE_FILE") || return 1
  else
    read -rp "$prompt" value </dev/tty || return 1
  fi
  printf -v "$dest_var" '%s' "$value"
}

# ---------------------------------------------------------------------------
# Environment guards
# ---------------------------------------------------------------------------

check_nested_tmux() {
  [[ -n "${TMUX:-}" ]] || return 0
  local current
  current=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
  if [[ "$current" != "$TMUX_SESSION_NAME" ]]; then
    printf '[qqq] refusing to run inside tmux session "%s". Run qqq outside tmux, or reattach to the existing "%s" session first.\n' \
      "$current" "$TMUX_SESSION_NAME" >&2
    exit 1
  fi
}

acquire_lock() {
  local sess="$1"
  local lock_file="$sess/.qqq.lock"
  # fd 9 stays open for the lifetime of this process; flock releases on exit.
  exec 9<>"$lock_file"
  if ! flock -n 9; then
    local owner
    owner=$(cat "$lock_file" 2>/dev/null)
    owner=${owner:-unknown}
    printf '[qqq] session "%s" is locked by PID %s — another qqq running?\n' \
      "$(basename "$sess")" "$owner" >&2
    exec 9<&- 2>/dev/null || true
    return 1
  fi
  # Overwrite with our PID only after acquiring.
  printf '%s\n' "$$" >"$lock_file"
}

release_session_lock() {
  flock -u 9 2>/dev/null || true
  exec 9<&- 2>/dev/null || true
}
