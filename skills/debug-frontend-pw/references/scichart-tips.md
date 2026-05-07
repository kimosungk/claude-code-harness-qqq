# scichart-tips — Appendix for SciChart-based chart defects

Notes on SciChart-specific behaviors that cause defects. Read only when investigating a chart/WebGL issue.

## Common entry point — accessing the surface

SciChart is a separate WASM instance from React. You can't traverse from a DOM element to the surface directly. If the project already exposes a debug hook that puts the surface on `window`, use it. Otherwise:

1. **Temporary expose**: Locate the `SciChartSurface.create` call site and add a one-liner that pushes to `(window as any).__debug_surfaces = [...]` (tag it `// [DBG]`). Revert in teardown.
2. **Store via useState setter**: If `const [surface, setSurface] = useState(...)` already exists, it's fine to also park it in a Zustand store. Simplest path.
3. **Access only inside the source**: If the surface is captured in a closure (e.g., `useEffect(() => { ... surface.yAxes.get(0) ... })`), inject the log point at that exact site.

## Y visibleRange / autoRange behavior (validated in session)

**SciChart v5**:

- `yAxis.autoRange = EAutoRange.Once` is meant to "autoRange once on the next render, then Never".
- **However, once `visibleRange` is explicitly set in code (via `yAxis.visibleRange = new NumberRange(...)` or through `surface.zoomExtentsY()` internally), any later `autoRange = Once` assignment is not effective.**
- The property value remains `'Once'`, but the autoRange latch on the next frame is not re-planted.
- Evidence: in `data.rAF`, the autoRange property stays `'Once'` while Y visibleRange keeps its prior value instead of reflecting the full data extent (the narrow-zoom Y-stuck bug).

### Where this bites you

- A drag-zoom sets `yAxis.visibleRange` → a subsequent reset path tries to recover via `autoRange = Once` → no effect → Y stays stuck.
- Response: **explicitly set visibleRange**. Assign `yAxis.visibleRange = new NumberRange(dataMin, dataMax * (1 + growBy))` directly.

### Recommended capture points

On a chart's Y-reset path, log at:

```
sub.entry              ← reset signal enters
sub.afterAutoOnce      ← right after autoRange = Once
sub.afterZoomExtentsY  ← after zoomExtentsY() (if used)
sub.rAF                ← one frame later

data.entry             ← dataEffect enters (refetch result arrived)
data.afterAppend       ← after series.appendRange()
data.afterOnce         ← right after autoRange = Once
data.rAF               ← one frame later
```

At each point record `{yMin, yMax, autoRange, dataMin?, dataMax?, len?}`.

## The hidden trap of `zoomExtentsY()`

`surface.zoomExtentsY()` recomputes Y based on **the Y extent of the series data within the current X visibleRange**.

- Called while X is narrow → fits Y to the narrow X-slice's data only
- Later X returns to full, but Y stays narrow (visibleRange is explicitly set)

→ If a reset path calls `zoomExtentsY()` **before** X returns and full data loads, it makes things worse. It is only effective **after** X is restored and full data has been appended.

## Canvas coordinate measurement

One canvas per chart in SciChart. Viewport offset via `getBoundingClientRect()`.

```javascript
() => Array.from(document.querySelectorAll('canvas')).map((c, i) => {
  const r = c.getBoundingClientRect();
  return { i, x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
})
```

For the Y pixel of a specific value inside a canvas:
- Read the min/max of axis labels from a screenshot and linearly interpolate
- Or use SciChart's `CoordinateCalculator.getCoordinate(value)` (requires the surface to be exposed)

Screenshot + interpolation is usually fastest and accurate enough.

## Drag zoom / dblclick events

SciChart listens on PointerEvents. Dispatching only mousedown/mouseup won't let SciChart recognize a dblclick.

- **Drag zoom**: `mousemove → mousedown → mousemove → mouseup` works (pointer events ride along).
- **Dblclick on canvas**: dispatch `new MouseEvent('dblclick', {...})` on the element directly.
- **Validated in session**: playwright-cli's `mousemove/down/up` appear to also emit PointerEvents, so drag zoom works. Only dblclick needs explicit dispatch.

## Why autoRange is invalid after appendRange (hypothesis)

Likely SciChart NumericAxis flow (v5):

```
yAxis.visibleRange = NEW_RANGE   ← user set
  └─ _isUserSet = true (internal flag)

next render:
  updateAutoRange()
    if (autoRange === Once)
      if (_isUserSet) return   ← skip
      computeAndSet()
      _autoRangeLatched = true
```

SciChart source is proprietary, so this is a hypothesis — but **session evidence** (autoRange stays `'Once'`, Y doesn't change) matches the shape.

## Recommended fix directions (memo for ANALYSIS.md)

1. On the reset path, **after** data arrives, explicitly `yAxis.visibleRange = new NumberRange(dataMin, dataMax)`. Abandon the `autoRange = Once` assumption.
2. Put a signal (e.g. `pendingYReset`) in the store; consume it right after `series.appendRange` in dataEffect.
3. For UI state that must be reflected, assert values one frame after calling the setter (tests).

Do not implement any of these in this skill. Capture them in ANALYSIS.md as a **memo** only.
