# xvfb-setup — Headed browser on a host without DISPLAY

For server/container environments where `$headed=yes` is required but `$DISPLAY` is empty.

## Pre-flight check

```bash
if [ -n "$DISPLAY" ]; then
  # DISPLAY is already set — Xvfb is unnecessary
  XVFB_DISPLAY="${DISPLAY#:}"
  XVFB_PID=""
  return 0
fi

# Is Xvfb installed?
if ! command -v Xvfb >/dev/null 2>&1; then
  echo "Xvfb not installed. Install: sudo apt install xvfb"
  echo "Or fall back to headless."
  exit 2   # caller should offer a fallback via AskUserQuestion
fi
```

## Pick a random display number (avoid collision)

Avoid `:99` collisions across parallel skill instances. Try a random value in 80..99, skipping any in use.

```bash
for attempt in 1 2 3; do
  N=$(( 80 + RANDOM % 20 ))
  [ -e "/tmp/.X11-unix/X$N" ] && continue
  XVFB_DISPLAY=$N
  break
done

if [ -z "$XVFB_DISPLAY" ]; then
  echo "Could not find free Xvfb display in :80-:99"
  exit 2
fi
```

## Start

```bash
Xvfb ":$XVFB_DISPLAY" -screen 0 1920x1080x24 -ac > "/tmp/${UI_DEBUG_PW_ID}-xvfb.log" 2>&1 &
XVFB_PID=$!
disown

# Wait up to 2s for the socket to appear
for i in 1 2 3 4; do
  [ -e "/tmp/.X11-unix/X$XVFB_DISPLAY" ] && break
  sleep 0.5
done

if [ ! -e "/tmp/.X11-unix/X$XVFB_DISPLAY" ]; then
  kill "$XVFB_PID" 2>/dev/null
  echo "Xvfb failed to start"
  exit 2
fi

echo "Xvfb ready :$XVFB_DISPLAY (pid=$XVFB_PID)"
```

## Usage rules

- Prefix `playwright-cli open` with `DISPLAY=:$XVFB_DISPLAY`.
- Later `playwright-cli -s=<session> <cmd>` calls do NOT need the DISPLAY prefix (the session is already attached).
- Record `XVFB_DISPLAY` and `XVFB_PID` to MARKER.

## Teardown

```bash
[ -n "$XVFB_PID" ] && kill -TERM "$XVFB_PID" 2>/dev/null
sleep 0.5
[ -n "$XVFB_PID" ] && kill -KILL "$XVFB_PID" 2>/dev/null
rm -f "/tmp/${UI_DEBUG_PW_ID}-xvfb.log"
```

## Limitations

- Xvfb uses software rendering. Some WebGL implementations may behave differently from a real GPU (rarely an issue in practice).
- Playwright Chrome on Xvfb renders WebGL via SwiftShader. WebGL charts such as SciChart **reproduce reliably** here (validated in session).
- If real GPU rendering is strictly required, the user must run the skill in an environment with a real `DISPLAY`.
