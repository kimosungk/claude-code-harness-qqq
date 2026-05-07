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

title='qqq notification'
body=$(json_get '.message')
if [[ -z "$body" ]]; then
  body=$(json_get '.notification')
fi
if [[ -z "$body" ]]; then
  body=$(json_get '.permission_prompt')
fi
if [[ -z "$body" ]]; then
  body=$(json_get '.idle_prompt')
fi
if [[ -z "$body" ]]; then
  body=$(json_get '.elicitation_dialog')
fi
if [[ -z "$body" ]]; then
  body='Claude session requires attention.'
fi

if [[ -z "$title" ]]; then
  title='qqq notification'
fi

case "$(uname -s)" in
  Darwin)
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1 || true
    elif command -v osascript >/dev/null 2>&1; then
      osascript -e 'display notification (item 1 of argv) with title (item 2 of argv)' -- "$body" "$title" >/dev/null 2>&1 || true
    else
      printf '[qqq-hooks] notifier unavailable on macOS; skipped notification.\n' >&2
    fi
    ;;
  Linux)
    if command -v notify-send >/dev/null 2>&1; then
      notify-send "$title" "$body" >/dev/null 2>&1 || true
    else
      printf '[qqq-hooks] notify-send unavailable; skipped notification.\n' >&2
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if command -v powershell.exe >/dev/null 2>&1; then
      QQQ_NOTIFY_BODY="$body" QQQ_NOTIFY_TITLE="$title" powershell.exe -NoProfile -Command '
$msg = $env:QQQ_NOTIFY_BODY
$ttl = $env:QQQ_NOTIFY_TITLE
if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
  New-BurntToastNotification -Text $ttl, $msg | Out-Null
} else {
  Write-Error "[qqq-hooks] BurntToast unavailable; skipped notification."
}
' >/dev/null 2>&1 || true
    else
      printf '[qqq-hooks] powershell.exe unavailable; skipped notification.\n' >&2
    fi
    ;;
  *)
    printf '[qqq-hooks] unsupported platform for notifications; skipped.\n' >&2
    ;;
esac

exit 0
