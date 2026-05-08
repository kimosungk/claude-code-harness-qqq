#!/usr/bin/env bash

set -euo pipefail

payload=$(cat)
if [[ -z "$payload" ]]; then
  payload='{}'
fi

json_get() {
  local filter="$1"
  jq -r "$filter // empty" <<<"$payload" 2>/dev/null || true
}

resolve_agent_type() {
  local resolved
  resolved=$(json_get '.agent_type')
  if [[ -z "$resolved" ]]; then
    resolved=$(json_get '.subagent_type')
  fi
  if [[ -z "$resolved" ]]; then
    resolved=$(json_get '.task.agent_type')
  fi
  if [[ -z "$resolved" ]]; then
    resolved=$(json_get '.task.subagent_type')
  fi
  if [[ -z "$resolved" ]]; then
    resolved="${QQQ_AGENT:-}"
  fi
  resolved="${resolved##*:}"
  printf '%s\n' "$resolved"
}

emit_block() {
  local reason="$1"
  jq -cn --arg decision "block" --arg reason "$reason" '{decision:$decision, reason:$reason}'
  exit 0
}

stop_active="${stop_hook_active:-}"
if [[ -z "$stop_active" ]]; then
  stop_active=$(json_get '.stop_hook_active')
fi
if [[ "$stop_active" == "true" ]]; then
  exit 0
fi

agent_type=$(resolve_agent_type)
session_dir="${QQQ_SESSION_DIR:-}"
if [[ -z "$agent_type" || -z "$session_dir" ]]; then
  exit 0
fi

missing=()
case "$agent_type" in
  req-clarifier)
    [[ -f "$session_dir/phase1-spec.md" ]] || missing+=(phase1-spec.md)
    ;;
  tech-interviewer)
    [[ -f "$session_dir/phase1-tech-spec.md" ]] || missing+=(phase1-tech-spec.md)
    ;;
  nltp-interviewer)
    [[ -f "$session_dir/phase1-nltp.md" ]] || missing+=(phase1-nltp.md)
    if ! compgen -G "$session_dir/phase1-nltp-review-*.md" >/dev/null; then
      missing+=('phase1-nltp-review-*.md')
    fi
    ;;
  code-planner)
    [[ -f "$session_dir/phase2-code-plan.md" ]] || missing+=(phase2-code-plan.md)
    [[ -f "$session_dir/phase2-review-log.md" ]] || missing+=(phase2-review-log.md)
    ;;
  code-implementer)
    [[ -f "$session_dir/phase3-implement-log.md" ]] || missing+=(phase3-implement-log.md)
    if ! compgen -G "$session_dir/phase3-*-review-*.md" >/dev/null; then
      missing+=('phase3-*-review-*.md')
    fi
    ;;
  # ── Reviewer subagents (SubagentStop event) ─────────────────────────────
  # Defense-in-depth only: parents (planner/implementer/nltp-interviewer)
  # already verify per-round artifacts. The hook cannot match exact round
  # numbers, so it only checks that *some* artifact of the expected shape
  # exists. False negatives possible (round-2 fails after round-1 wrote);
  # treat hook as a backstop, not a primary gate.
  nltp-reviewer)
    if ! compgen -G "$session_dir/phase1-nltp-review-*.md" >/dev/null; then
      missing+=('phase1-nltp-review-*.md')
    fi
    ;;
  code-plan-review-explorer)
    if ! compgen -G "$session_dir/phase2-g1-explorer-*.md" >/dev/null; then
      missing+=('phase2-g1-explorer-*.md')
    fi
    ;;
  code-plan-review-architect)
    if ! compgen -G "$session_dir/phase2-g2-architect-*.md" >/dev/null; then
      missing+=('phase2-g2-architect-*.md')
    fi
    ;;
  code-plan-review-critic)
    if ! compgen -G "$session_dir/phase2-g3-critic-*.md" >/dev/null; then
      missing+=('phase2-g3-critic-*.md')
    fi
    ;;
  code-implement-reviewer)
    if ! compgen -G "$session_dir/phase3-codex-review-*.md" >/dev/null \
        && ! compgen -G "$session_dir/phase3-claude-review-*.md" >/dev/null; then
      missing+=('phase3-codex-review-*.md or phase3-claude-review-*.md')
    fi
    ;;
esac

if (( ${#missing[@]} > 0 )); then
  emit_block "missing required qqq artifacts for ${agent_type}: ${missing[*]}"
fi

exit 0
