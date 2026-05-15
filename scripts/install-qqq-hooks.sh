#!/usr/bin/env bash

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf '[qqq-hooks] requires bash 4+ (found %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_root=$(cd "$script_dir/.." && pwd)
hook_src_dir="$plugin_root/hooks"
validate_script="$script_dir/validate-qqq-hooks.sh"

readonly required_hooks=(
  qqq-protect-files.sh
  qqq-context.sh
)

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[qqq-hooks] required command not found: %s\n' "$1" >&2
    if [[ "$1" == "jq" ]]; then
      printf '[qqq-hooks] install jq first, then rerun. Examples: brew install jq | sudo apt-get install jq | sudo dnf install jq\n' >&2
    fi
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

merge_settings() {
  local settings_path="$1"
  local tmp_path="$2"

  jq -s '.[0] |   # guard against multi-document files from repeated installs
    def is_qqq_command($command):
      ($command | test("(^|[[:space:]])\\.claude/hooks/qqq-[^[:space:]]+\\.sh([[:space:]]|$)"));

    def qqq_handler($matcher; $command):
      if ($matcher | length) > 0 then
        {
          matcher: $matcher,
          hooks: [
            {
              type: "command",
              command: $command
            }
          ]
        }
      else
        {
          hooks: [
            {
              type: "command",
              command: $command
            }
          ]
        }
      end;

    def strip_qqq_commands:
      if (type == "object") and ((.hooks? | type) == "array") then
        .hooks |= map(select((is_qqq_command(.command? // "")) | not))
      else
        .
      end;

    def event_entries($root; $event):
      if ($root.hooks[$event] // null) == null then
        []
      elif ($root.hooks[$event] | type) == "array" then
        $root.hooks[$event]
      else
        error("hooks." + $event + " must be an array")
      end;

    def merge_event($root; $event; $matcher; $command):
      (
        event_entries($root; $event)
        | map(strip_qqq_commands)
        | map(
            if (type == "object") and ((.hooks? | type) == "array") then
              select((.hooks | length) > 0)
            else
              .
            end
          )
      ) + [qqq_handler($matcher; $command)];

    . as $root
    | if ($root | type) != "object" then
        error("settings root must be a JSON object")
      else
        .
      end
    | .hooks = (
        if (.hooks // null) == null then
          {}
        elif (.hooks | type) == "object" then
          .hooks
        else
          error("hooks must be a JSON object")
        end
      )
    # Matcher = "Edit|Write|Bash". The Edit|Write arm enforces phase
    # artifact ownership for files under claude-works-completed/; the Bash
    # arm hard-blocks shell commands targeting the same paths. Migration
    # v2.3 dropped TaskCreated/TaskCompleted (qqq-log-event), Notification
    # (qqq-notify), Stop/SubagentStop (qqq-stop-guard) — those hooks are
    # replaced by agent view + skill-inline D1- gate.
    | .hooks.PreToolUse = merge_event($root; "PreToolUse"; "Edit|Write|Bash"; ".claude/hooks/qqq-protect-files.sh")
    | .hooks.SessionStart = merge_event($root; "SessionStart"; "startup|resume|compact"; ".claude/hooks/qqq-context.sh")
    # Strip qqq-owned commands from deprecated event groups (v2 → v3 cleanup).
    # Non-qqq handlers in those groups are preserved; empty groups are removed.
    | reduce ("TaskCreated","TaskCompleted","Notification","Stop","SubagentStop") as $ev (
        .;
        if (.hooks[$ev] // null) != null then
          .hooks[$ev] = (
            (.hooks[$ev] // [])
            | map(strip_qqq_commands)
            | map(select((.hooks? // []) | length > 0))
          )
          | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
        else
          .
        end
      )
  ' "$settings_path" >"$tmp_path"
}

print_summary() {
  local settings_path="$1"
  shift
  local files=("$@")

  if (( ${#files[@]} > 0 )); then
    printf '[qqq-hooks] changed files:\n'
    printf '  - %s\n' "${files[@]}"
  else
    printf '[qqq-hooks] no file content changes were needed.\n'
  fi

  printf '[qqq-hooks] active qqq hook groups:\n'
  jq -r '
    [
      {event:"PreToolUse", matcher:"Edit|Write|Bash", command:".claude/hooks/qqq-protect-files.sh"},
      {event:"SessionStart", matcher:"startup|resume|compact", command:".claude/hooks/qqq-context.sh"}
    ]
    | .[]
    | "- " + .event
      + (if .matcher != "" then " [matcher=" + .matcher + "]" else "" end)
      + " -> " + .command
  ' "$settings_path"
}

need jq

project_root=$(resolve_project_root "${1:-}")
claude_dir="$project_root/.claude"
hooks_dir="$claude_dir/hooks"
settings_path="$claude_dir/settings.json"
mkdir -p "$claude_dir"

changed_files=()

tmp_settings=$(mktemp)
trap 'rm -f "$tmp_settings"' EXIT

settings_existed=0
if [[ -f "$settings_path" ]]; then
  settings_existed=1
  jq . "$settings_path" >/dev/null
else
  printf '{}\n' >"$settings_path"
fi

merge_settings "$settings_path" "$tmp_settings"

before_norm=""
if (( settings_existed )); then
  before_norm=$(jq -S . "$settings_path")
fi
after_norm=$(jq -S . "$tmp_settings")

if (( ! settings_existed )); then
  mv "$tmp_settings" "$settings_path"
  changed_files+=(".claude/settings.json")
  trap - EXIT
elif [[ "$before_norm" != "$after_norm" ]]; then
  backup_path="$claude_dir/settings.json.bak.$(date '+%Y%m%d-%H%M%S')"
  cp "$settings_path" "$backup_path"
  mv "$tmp_settings" "$settings_path"
  changed_files+=(".claude/settings.json" ".claude/$(basename "$backup_path")")
  trap - EXIT
fi

mkdir -p "$hooks_dir"

for hook_name in "${required_hooks[@]}"; do
  src="$hook_src_dir/$hook_name"
  dest="$hooks_dir/$hook_name"
  if [[ ! -f "$src" ]]; then
    printf '[qqq-hooks] missing plugin hook template: %s\n' "$src" >&2
    exit 1
  fi

  file_changed=0
  if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
    cp "$src" "$dest"
    file_changed=1
  fi
  chmod +x "$dest"
  if (( file_changed )); then
    changed_files+=(".claude/hooks/$hook_name")
  fi
done

"$validate_script" "$project_root"
print_summary "$settings_path" "${changed_files[@]}"
