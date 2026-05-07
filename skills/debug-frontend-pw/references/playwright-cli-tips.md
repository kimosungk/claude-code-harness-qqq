# playwright-cli tips — Sessions / coordinates / eval patterns

Read in SKILL.md Step 3.

## Session ground rules

- Session name: `dbg-$UI_DEBUG_PW_ID` (avoids collision with parallel skill instances)
- All commands take the form `playwright-cli -s=<session> <command>`
- The `--headed` flag is only valid on `open`; later calls don't need it.

## Basic flow

```bash
source "$MARKER"
SESSION="dbg-$UI_DEBUG_PW_ID"
BASE_URL="http://127.0.0.1:$PORT"

# DISPLAY prefix only when headed
[ -n "$XVFB_DISPLAY" ] && DPX="DISPLAY=:$XVFB_DISPLAY" || DPX=""

$DPX playwright-cli -s=$SESSION open "$BASE_URL" $([ "$HEADED" = "yes" ] && echo "--headed")
sleep 3
playwright-cli -s=$SESSION resize 1920 1080
playwright-cli -s=$SESSION goto "$BASE_URL/<target-route>"
sleep 4
```

## Five repro-interaction patterns

### 1. Plain click

```bash
playwright-cli -s=$SESSION snapshot > /tmp/snap.yml
grep -n 'button "Submit"' /tmp/snap.yml   # find the ref
playwright-cli -s=$SESSION click e123
```

### 2. Plain dblclick (element-ref based — OK)

```bash
playwright-cli -s=$SESSION dblclick e456
```

### 3. Dblclick on a canvas/WebGL area — **ref-based fails**

For a specific coordinate inside a SciChart-like canvas, the element ref points at the whole canvas, which lacks precision. Substituting a `MouseEvent("dblclick")` via `mousedown/mouseup` won't trigger SciChart either, because SciChart listens on PointerEvents and plain MouseEvents only partly propagate.

**Workaround — dispatch directly via eval**:

```bash
playwright-cli -s=$SESSION eval "() => {
  const el = document.elementFromPoint(1200, 850);
  const evt = new MouseEvent('dblclick', {
    bubbles: true, cancelable: true, view: window,
    button: 0, clientX: 1200, clientY: 850, detail: 2
  });
  el.dispatchEvent(evt);
  return el ? el.tagName : 'miss';
}"
```

### 4. Drag (mouse-coordinate based)

```bash
playwright-cli -s=$SESSION mousemove 1460 720
playwright-cli -s=$SESSION mousedown
playwright-cli -s=$SESSION mousemove 1600 770
playwright-cli -s=$SESSION mouseup
sleep 2
```

### 5. Type / fill

```bash
playwright-cli -s=$SESSION fill e789 "search text"
# Or via keyboard
playwright-cli -s=$SESSION press Enter
```

## Canvas coordinate measurement

Viewport 1920x1080 assumed. Multiple canvases may coexist (SciChart uses one canvas per chart).

```bash
playwright-cli -s=$SESSION eval "() => {
  const cs = Array.from(document.querySelectorAll('canvas'));
  return cs.map((c, i) => {
    const r = c.getBoundingClientRect();
    return { i, x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  });
}" --raw
```

For chart-specific coordinate-to-value mapping (SciChart, etc.), see `references/scichart-tips.md`. In practice, reading axis labels from a screenshot and linearly interpolating is usually fastest.

## Screenshots

```bash
playwright-cli -s=$SESSION screenshot
# File path: .playwright-cli/page-<ISO-timestamp>.png
ls -t .playwright-cli/page-*.png | head -1   # the most recent
```

Use the Read tool to open the PNG so Claude can inspect it visually.

## Snapshot (DOM tree)

```bash
playwright-cli -s=$SESSION snapshot > /tmp/snap.yml
```

Find element refs (e1, e2, ...) via `grep -n` to target the next click/dblclick.

## eval caveats

- Invoke as `playwright-cli ... eval '<func>' --raw`. The `<func>` must be a `() => {...}` form.
- The return value must be JSON-serializable. Never return a DOM element directly — extract only the properties you need.
- Long evals can be wrapped as `(() => { ... })()` IIFEs.

## Session lifecycle & teardown

```bash
# Check
playwright-cli list | grep "dbg-$UI_DEBUG_PW_ID"

# Teardown
playwright-cli -s="dbg-$UI_DEBUG_PW_ID" close
```

## Common failure signatures

| Symptom | Cause / Fix |
|---|---|
| `dblclick <ref>` server validation error | Ref points at a canvas — use the eval dispatch pattern |
| Repeating mousedown/up doesn't fire dblclick | SciChart reacts to PointerEvents — MouseEvents aren't forwarded; use `dispatchEvent` |
| Empty snapshot after goto | Sleep 3–5s after goto to allow initial React render + chart WASM init |
| Repro doesn't happen | URL state differs from the scenario — recheck current page state via snapshot |
