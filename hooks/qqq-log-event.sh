#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd "$script_dir/../.." && pwd)

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

is_session_dir() {
  local dir="$1"
  [[ -f "$dir/phase1-spec.md" \
    || -f "$dir/phase2-code-plan.md" \
    || -f "$dir/phase3-implement-log.md" \
    || -f "$dir/.qqq.lock" \
    || -d "$dir/.qqq" ]]
}

log_file_for() {
  local cwd="$1"
  if [[ -n "${QQQ_SESSION_DIR:-}" && -d "${QQQ_SESSION_DIR:-}" ]]; then
    printf '%s/.qqq/log.jsonl\n' "$QQQ_SESSION_DIR"
  elif is_session_dir "$cwd"; then
    printf '%s/.qqq/log.jsonl\n' "$cwd"
  else
    printf '%s/.claude/qqq/log.jsonl\n' "$project_root"
  fi
}

hook_event=$(json_get '.hook_event_name')
if [[ -z "$hook_event" ]]; then
  hook_event=$(json_get '.event_name')
fi
if [[ -z "$hook_event" ]]; then
  hook_event=$(json_get '.event')
fi

event_name="task_event"
result="ok"
case "$hook_event" in
  TaskCreated)
    event_name="task_created"
    result="started"
    ;;
  TaskCompleted)
    event_name="task_completed"
    result="completed"
    ;;
esac

cwd=$(pwd)
log_file=$(log_file_for "$cwd")
mkdir -p "$(dirname "$log_file")"

details=$(jq -c '
  {
    hook_event_name: (.hook_event_name // .event_name // .event // "unknown"),
    task_id: (.task_id // .id // ""),
    parent_task_id: (.parent_task_id // ""),
    task_title: (.task_title // .title // ""),
    payload_details: (.details // {})
  }' <<<"$payload" 2>/dev/null || jq -cn --arg raw "$payload" '{raw_payload:$raw}')

jq -cn \
  --arg schema_version "1" \
  --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')" \
  --arg source "hook" \
  --arg event "$event_name" \
  --arg result "$result" \
  --arg agent_type "$(resolve_agent_type)" \
  --arg session_dir "${QQQ_SESSION_DIR:-}" \
  --arg cwd "$cwd" \
  --argjson details "$details" \
  '{schema_version:$schema_version,ts:$ts,source:$source,event:$event,result:$result,agent_type:$agent_type,session_dir:$session_dir,cwd:$cwd,details:$details}' \
  >>"$log_file"
