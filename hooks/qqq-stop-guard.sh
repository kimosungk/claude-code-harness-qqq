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
esac

if (( ${#missing[@]} > 0 )); then
  emit_block "missing required qqq artifacts for ${agent_type}: ${missing[*]}"
fi

exit 0
