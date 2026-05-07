# env-isolation — Isolated dev server bootstrap (MARKER / PGID / setsid)

Read this file in SKILL.md Step 1. Adapts the `ui-verifier` pattern for debug-frontend-pw.

## devcmd file convention

Location: `<CLAUDE_WORKS>/debug-frontend-pw.devcmd` (under the CLAUDE_WORKS resolved in Step 0)

Format (line-prefix; order doesn't matter):

```
mock=VITE_USE_MOCK=true pnpm dev
real=pnpm dev
```

- One line per mode: `mock=<command>` or `real=<command>`
- Lines starting with `#` are comments (ignored)
- Blank lines are ignored
- Split on the **first** `=`; the value may contain further `=` characters
- If the file is missing, use the built-in defaults (see SKILL.md Defaults)
- If the requested `$mode` line is missing, fall back to the built-in default

Parsing snippet:

```bash
DEVCMD_FILE="$CLAUDE_WORKS/debug-frontend-pw.devcmd"
MODE="$1"   # mock | real

DEV_CMD=""
if [ -f "$DEVCMD_FILE" ]; then
  DEV_CMD=$(awk -F= -v mode="$MODE" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $1==mode { sub(/^[^=]*=/, ""); print; exit }
  ' "$DEVCMD_FILE")
fi

if [ -z "$DEV_CMD" ]; then
  if [ "$MODE" = "real" ]; then
    DEV_CMD="pnpm dev"
  else
    DEV_CMD="VITE_USE_MOCK=true pnpm dev"
  fi
fi
```

## Sweep dead-session MARKERs

**Never touch live process groups** — they may belong to other active sessions.

```bash
for old in /tmp/uidbg-*.env; do
  [ -f "$old" ] || continue
  old_pgid=$(awk -F= '/^PGID=/{print $2}' "$old")
  if [ -n "$old_pgid" ] && ! kill -0 -"$old_pgid" 2>/dev/null; then
    # PGID is dead — best-effort kill any orphan Xvfb recorded in the marker, then drop marker/log
    old_xvfb=$(awk -F= '/^XVFB_PID=/{print $2}' "$old")
    [ -n "$old_xvfb" ] && kill -0 "$old_xvfb" 2>/dev/null && kill "$old_xvfb" 2>/dev/null
    rm -f "$old" "/tmp/$(basename "$old" .env).log"
  fi
done
```

## Unique ID + random port + new process group

```bash
UI_DEBUG_PW_ID="uidbg-$(date +%s)-$$-$RANDOM"
MARKER="/tmp/${UI_DEBUG_PW_ID}.env"
LOG="/tmp/${UI_DEBUG_PW_ID}.log"
PIDFILE=$(mktemp)

started=0
for attempt in 1 2 3; do
  UI_DEBUG_PW_PORT=$(( 55000 + RANDOM % 1000 ))
  ss -ltn "sport = :$UI_DEBUG_PW_PORT" 2>/dev/null | grep -q ":$UI_DEBUG_PW_PORT" && continue

  # setsid -f detaches into a new session/pgid, away from the parent shell
  # Append --port and --strictPort after the user DEV_CMD
  setsid -f bash -c "echo \$\$ > '$PIDFILE'; exec env UI_DEBUG_PW_ID='$UI_DEBUG_PW_ID' $DEV_CMD -- --port $UI_DEBUG_PW_PORT --strictPort" >> "$LOG" 2>&1

  for i in 1 2 3 4 5; do [ -s "$PIDFILE" ] && break; sleep 0.1; done
  PGID=$(cat "$PIDFILE" 2>/dev/null)
  [ -z "$PGID" ] && continue

  # Wait up to 30s for vite to respond; break early if the process died (e.g. strictPort collision)
  for i in $(seq 30); do
    curl -s -o /dev/null "http://127.0.0.1:$UI_DEBUG_PW_PORT" && started=1 && break
    kill -0 "$PGID" 2>/dev/null || break
    sleep 1
  done
  [ "$started" = 1 ] && break

  # This attempt failed — kill the whole group and try another port
  kill -KILL -"$PGID" 2>/dev/null
  : > "$PIDFILE"
done
rm -f "$PIDFILE"

if [ "$started" != 1 ]; then
  echo "dev server failed to start after 3 attempts; log: $LOG"
  exit 1
fi

cat > "$MARKER" <<EOF
UI_DEBUG_PW_ID=$UI_DEBUG_PW_ID
PGID=$PGID
PORT=$UI_DEBUG_PW_PORT
LOG=$LOG
MODE=$MODE
DEV_CMD=$DEV_CMD
EOF

echo "READY  MARKER=$MARKER  PORT=$UI_DEBUG_PW_PORT  PGID=$PGID  MODE=$MODE"
```

**Record the MARKER path.** Tool-call boundaries reset shell state, so every subsequent Bash invocation must begin with `source "$MARKER"` to restore state.

## Additional Xvfb startup for headed

If `$headed=yes` and `$DISPLAY` is empty, read `references/xvfb-setup.md`, bring up Xvfb, then append the following to MARKER:

```bash
cat >> "$MARKER" <<EOF
XVFB_DISPLAY=$XVFB_DISPLAY
XVFB_PID=$XVFB_PID
EOF
```

## Env-tag guard during teardown

Guards against PGID reuse. Only kill if the MARKER's `UI_DEBUG_PW_ID` still lives in the current PGID's env.

```bash
source "$MARKER"

if grep -qaz "UI_DEBUG_PW_ID=$UI_DEBUG_PW_ID" "/proc/$PGID/environ" 2>/dev/null; then
  kill -TERM -"$PGID" 2>/dev/null
  sleep 1
  kill -KILL -"$PGID" 2>/dev/null
else
  echo "PGID $PGID no longer ours — skipping kill"
fi
```

## Notes

- Avoid having multiple skill instances update the same MARKER file — always generate a unique, ID-based filename.
- When the dev server is warm from HMR, parallel runs depend on port isolation — `--strictPort` is mandatory.
- The MARKER's `UI_DEBUG_PW_ID` is exported as an env var and stays on the child's `/proc/<pid>/environ`, which is what the PGID guard relies on.
- **The skill never creates the devcmd file.** The user writes it per project. If absent, built-in defaults apply.
