#!/usr/bin/env bash

set -euo pipefail

# qqq-protect-files (v2.3 — Q2=가)
# Sole responsibility: deny any write under claude-works-completed/.
# Launcher-owned/agent-ownership checks were retired with .qqq.lock,
# .qqq/session.json, and the workflow controller (migration v2.3).

if git rev-parse --show-toplevel >/dev/null 2>&1; then
  project_root=$(git rev-parse --show-toplevel)
else
  project_root="$PWD"
fi

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

# Bash arm — catch only destructive verbs (rm/rmdir/shred) targeting the
# archive. Earlier versions used a broad substring match (*claude-works-completed/*)
# which had two failure modes:
#   1. legitimate merge-mr archive (`git mv claude-works/x claude-works-completed/x`)
#      was blocked, breaking Phase 3 → merge handoff;
#   2. any benign command merely *mentioning* the path (echo, grep, ls) was blocked,
#      causing operator friction.
# D1− principle: hooks are a light safety net, not a security boundary. Keep
# the catch narrow to obviously-destructive intent; rely on Edit/Write arm for
# silent-mutation prevention by the LLM.
command_str=$(json_get '.tool_input.command')
if [[ -n "$command_str" ]]; then
  # Extract the first word after stripping leading whitespace and any inline
  # env-var prefixes (e.g. `FOO=bar rm -rf …` → first token `rm`).
  first_token=$(printf '%s' "$command_str" \
    | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)+//' \
    | awk '{print $1}')
  case "$first_token" in
    rm|rmdir|shred|/bin/rm|/usr/bin/rm|/bin/rmdir|/usr/bin/rmdir)
      case "$command_str" in
        *claude-works-completed/*)
          block "destructive command targets claude-works-completed/* (frozen): $command_str"
          ;;
      esac
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
