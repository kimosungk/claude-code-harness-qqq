#!/usr/bin/env bash

set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[qqq-hooks] required command not found: %s\n' "$1" >&2
    exit 1
  }
}

resolve_project_root() {
  local input="${1:-}"
  if [[ -n "$input" ]]; then
    if [[ ! -d "$input" ]]; then
      printf '[qqq-hooks] project root does not exist: %s\n' "$input" >&2
      exit 1
    fi
    (cd "$input" && pwd)
    return 0
  fi
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

need jq

project_root=$(resolve_project_root "${1:-}")
settings_path="$project_root/.claude/settings.json"
hooks_dir="$project_root/.claude/hooks"

failures=()

if [[ ! -f "$settings_path" ]]; then
  failures+=("missing settings file: .claude/settings.json")
else
  if ! jq . "$settings_path" >/dev/null 2>&1; then
    failures+=("invalid JSON: .claude/settings.json")
  fi
fi

for hook_name in \
  qqq-protect-files.sh \
  qqq-context.sh; do
  hook_path="$hooks_dir/$hook_name"
  [[ -f "$hook_path" ]] || failures+=("missing hook script: .claude/hooks/$hook_name")
  [[ -x "$hook_path" ]] || failures+=("hook script is not executable: .claude/hooks/$hook_name")
done

if [[ -f "$settings_path" ]] && jq . "$settings_path" >/dev/null 2>&1; then
  mapfile -t schema_failures < <(
    jq -r '
      [
        (if (.hooks // null) != null and (.hooks | type) != "object" then
          "hooks must be a JSON object"
        else
          empty
        end),
        (["PreToolUse","SessionStart"][] as $event
          | if (.hooks[$event] // null) != null and (.hooks[$event] | type) != "array" then
              "hooks." + $event + " must be an array"
            else
              empty
            end)
      ] | .[]' "$settings_path"
  )
  if (( ${#schema_failures[@]} > 0 )); then
    failures+=("${schema_failures[@]}")
  fi

  mapfile -t validation_failures < <(
    jq -r '
      def is_qqq_command($command):
        ($command | test("(^|[[:space:]])\\.claude/hooks/qqq-[^[:space:]]+\\.sh([[:space:]]|$)"));

      def required:
        [
          {event:"PreToolUse", matcher:"Edit|Write|Bash", command:".claude/hooks/qqq-protect-files.sh"},
          {event:"SessionStart", matcher:"startup|resume|compact", command:".claude/hooks/qqq-context.sh"}
        ];

      def handlers_for($event):
        if (.hooks // null) == null then
          []
        elif (.hooks | type) != "object" then
          error("hooks must be a JSON object")
        elif (.hooks[$event] // null) == null then
          []
        elif (.hooks[$event] | type) != "array" then
          error("hooks." + $event + " must be an array")
        else
          .hooks[$event]
        end;

      [
        (required[] as $req
          | ([handlers_for($req.event)[]
              | select((.matcher // null) == $req.matcher)
              | .hooks[]?
              | select(.command? == $req.command)
            ]
              | length
            ) as $count
          | if $count == 1 then
              empty
            elif $count == 0 then
              "missing qqq handler: " + $req.event + " -> " + $req.command
            else
              "duplicate qqq handler: " + $req.event + " -> " + $req.command + " (" + ($count | tostring) + ")"
            end),
        (([
            .hooks[]?[]?.hooks[]?
            | .command? // empty
            | select(is_qqq_command(.))
          ] | length) as $total
          | if $total == 7 then empty else "unexpected total qqq-owned handler count: " + ($total | tostring) + " (expected 7)" end)
      ] | .[]' "$settings_path"
  )
  if (( ${#validation_failures[@]} > 0 )); then
    failures+=("${validation_failures[@]}")
  fi
fi

if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}" >&2
  exit 1
fi

printf '[qqq-hooks] validation passed for %s\n' "$project_root"
