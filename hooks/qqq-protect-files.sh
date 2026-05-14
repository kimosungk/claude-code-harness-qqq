#!/usr/bin/env bash

set -euo pipefail

# qqq-protect-files (v2.3 — Q2=가)
# Sole responsibility: deny any write under claude-works-completed/.
# Launcher-owned/agent-ownership checks were retired with .qqq.lock,
# .qqq/session.json, and the workflow controller (migration v2.3).

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

block() {
  local reason="$1"
  printf '[qqq-hooks] blocked edit: %s\n' "$reason" >&2
  exit 2
}

# Bash arm — catch redirect/cp/mv/rm that targets the archive even when no
# tool_input.file_path is present.
command_str=$(json_get '.tool_input.command')
if [[ -n "$command_str" ]]; then
  case "$command_str" in
    *claude-works-completed/*)
      block "Bash command targets claude-works-completed/* (frozen): $command_str"
      ;;
  esac
fi

# Edit|Write arm — derive file path from the standard tool envelope.
file_path=$(json_get '.tool_input.file_path')
[[ -z "$file_path" ]] && file_path=$(json_get '.tool_input.path')
[[ -z "$file_path" ]] && file_path=$(json_get '.file_path')

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Normalize to an absolute path and strip the project-root prefix so the
# substring match below is unambiguous regardless of cwd.
if [[ "$file_path" != /* ]]; then
  file_path="$PWD/$file_path"
fi
file_path=$(printf '%s' "$file_path" | sed 's#//*#/#g')

if [[ "$file_path" == "$project_root/"* ]]; then
  rel_path="${file_path#"$project_root"/}"
else
  rel_path="$file_path"
fi

if [[ "$rel_path" == claude-works-completed/* || "$rel_path" == */claude-works-completed/* ]]; then
  block "completed archive artifacts are frozen: $rel_path"
fi

exit 0
