# react-timing — effect / rAF / HMR ordering reference

Root-cause investigation often hinges on "who changes what, when". A precise mental model of React + external library timing is essential.

## React lifecycle order (single render pass)

```
1. Render phase
     ├─ functional component body runs
     ├─ JSX returned
     └─ hook selectors run (useState, useMemo, Zustand, ...)

2. Commit phase
     ├─ DOM mutation
     ├─ useLayoutEffect runs synchronously (all components)
     └─ before browser paint

3. Paint
     └─ pixels land on screen

4. Passive phase
     ├─ useEffect runs (async, after commit)
     └─ DOM / refs / layout are final at this point

5. Post-paint tasks
     ├─ requestAnimationFrame callback (right before next frame)
     ├─ microtask (Promise.then)
     └─ macrotask (setTimeout, message, ...)
```

Pick the right capture point:

| Goal | Best point |
|---|---|
| "State at effect entry" | Top of useEffect body |
| "State right after layout" | useLayoutEffect body |
| "State one frame after render" | requestAnimationFrame callback |
| "State after all microtasks" | `Promise.resolve().then(() => ...)` |

## Zustand subscribe ordering

Zustand's `store.subscribe(listener)` is **synchronous**. On `set()`, every listener runs in order immediately.

```
set(partial)
  └─ subscribe.listener[0]()   ← sync
  └─ subscribe.listener[1]()   ← sync
  └─ ...
  └─ subscribe.listener[N]()   ← sync
then React rerender is scheduled
```

→ If `store.setFlag()` is followed by `store.setXRange()`, the first listener sees state before X changes. The Y-reset bug in SKILL.md's example stems from this exact shape.

## When an external library call inserts itself

APIs like `surface.zoomExtentsY()`, `chart.redraw()`, `scene.render()` are synchronous. They compute internal state based on the **data state at call time** and do not auto-recompute when data later changes (depends on library policy).

### When a single-property set leaves a side effect

Some libraries treat `yAxis.visibleRange = new NumberRange(...)` setters as raising a "user-set" flag internally, blocking later autoRange recomputation. SciChart behaves this way (see `scichart-tips.md`).

→ Log both "right after set" and "next frame" to verify whether autoRange reactivates.

## HMR timing

Vite HMR:
1. File save → Vite detects change (hundreds of ms)
2. Writes `hmr update /src/...` to `/tmp/<LOG>`
3. Browser client swaps the module → the affected component re-mounts or its effect re-runs

How to check whether the injected code applied:

```bash
# Was there an hmr update in the last ~5 seconds?
tail -50 "$LOG" | grep -c "hmr update.*$(basename $TARGET_FILE)"

# Or, after saving, wait briefly
sleep 2
grep "hmr update" "$LOG" | tail -1
```

**Caution**: Changing the size of a `useEffect` dependency array triggers an HMR warning and can leave the effect unstable. When you need a clean state:

```bash
playwright-cli -s=$SESSION reload
sleep 5   # allow initial React render + chart WASM reinit
```

## Why `console.log` is dangerous (validated in session)

When DevTools is attached, `console.log` serializes its arguments and forwards them to DevTools through a microtask-consuming path. Consequences:

- Subscriber ordering inside event handlers shifts
- A Zustand set's listener runs one tick later than it would otherwise
- Net effect: **with the log, the bug hides; without it, the bug reappears**

→ Never use `console.log` for observation. Use the mutable push via `window.__debug.log()` as in `observation-injection.md`.

## Principles for placing capture points

1. Center on **the moment the bug happens**, with 3–5 points before/after
2. Each point's **order must be unambiguous** — effect entry, right after setter, right after autoRange reset, rAF, etc.
3. Use `scopeId` to disambiguate multiple instances (chart, row, etc.)
4. **Also record non-changes** — "value didn't change here" is strong evidence
5. Watch the **dt (ms)** gap between entries. Identical dt = synchronous; tens of ms of gap = an async boundary

## When repro fails — timing checklist

- [ ] Not enough sleep between mouse events, causing event coalescing?
- [ ] Did you attempt the repro before chart WASM init completed?
- [ ] Is a useEffect running on first render and skewing the true repro condition?
- [ ] Is React StrictMode's double invocation making the behavior look wrong? (dev build)
- [ ] Is HMR leaving an effect cleanup un-run? Reload required.
