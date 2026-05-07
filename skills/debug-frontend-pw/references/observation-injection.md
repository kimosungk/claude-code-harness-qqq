# observation-injection — window.__debug + source log markers

How to instrument the running browser to collect a time-ordered record of real values. Do **not** use `console.log` (risks perturbing microtask order).

## Injecting the window.__debug infrastructure

Inject once via playwright-cli eval:

```bash
playwright-cli -s=$SESSION eval "() => {
  window.__debug = {
    entries: [],
    t0: performance.now(),
    capMax: 1000,
    overflow: 0,
    log(scopeId, step, data) {
      if (this.entries.length >= this.capMax) { this.overflow++; return; }
      this.entries.push({
        dt: Math.round(performance.now() - this.t0),
        scopeId, step,
        ...data
      });
    },
    dump() { return this.entries; },
    summary() {
      return {
        count: this.entries.length,
        overflow: this.overflow,
        elapsed: Math.round(performance.now() - this.t0),
      };
    },
    clear() { this.entries = []; this.t0 = performance.now(); this.overflow = 0; }
  };
  return 'ok';
}" --raw
```

## Source log-point conventions

**Every injected line must carry a `// [DBG]` marker.** Teardown uses `grep` to check before calling `git checkout` to revert.

### 1. Single value capture point

Captures a value at a specific moment inside an effect / handler:

```typescript
// [DBG]
{
  // biome-ignore lint/suspicious/noExplicitAny: debug
  (window as any).__debug?.log(scopeId, 'step-name', {
    key1: value1,
    key2: value2,
  });
}
```

`scopeId` distinguishes instances (sensor id, chart id, component key, etc.). Make sure multiple instances can be disambiguated.

### 2. Post-frame capture point

For verifying values after autoRange / render / layout finishes:

```typescript
// [DBG] post-frame
requestAnimationFrame(() => {
  // biome-ignore lint/suspicious/noExplicitAny: debug
  (window as any).__debug?.log(scopeId, 'step-name.rAF', {
    key1: value1,
  });
});
```

### 3. Experimental line disable

Disable a line to verify causality:

```typescript
// [DBG-exp] EXPERIMENT A: this line disabled
// surface.zoomExtentsY();
```

Always use `// [DBG-exp]` to distinguish from `[DBG]`. Each experiment must change exactly one place (single-variable principle).

## Teardown guard

```bash
# Revert only files containing a [DBG] or [DBG-exp] marker
git diff --name-only | while read f; do
  if git diff "$f" | grep -qE '\[DBG(-exp)?\]'; then
    git checkout -- "$f"
    echo "reverted: $f"
  fi
done
```

`git checkout` is the real revert; the marker is a secondary safety check. Verify the final `git diff` is clean and every file modification was purely `[DBG]` related.

## Dump & analyze the timeline

```bash
playwright-cli -s=$SESSION eval "() => JSON.stringify(window.__debug.dump())" --raw \
  > "$ARTIFACT_DIR/ydebug-baseline.json"
```

Convert to a readable table (python):

```bash
cat "$ARTIFACT_DIR/ydebug-baseline.json" | python3 -c "
import json, sys
data = json.loads(json.load(sys.stdin))
for e in data:
    kv = {k:v for k,v in e.items() if k not in ('dt','scopeId','step')}
    extras = ' '.join(f'{k}={v}' for k,v in kv.items())
    print(f\"dt={e['dt']:4d}ms {e['scopeId']:10s} {e['step']:24s} {extras}\")
" > "$ARTIFACT_DIR/ydebug-baseline.txt"
```

If cap overflow occurs, note it in ANALYSIS.md and either raise `capMax` or reduce the number of log points and recapture.

## ❌ Do not

- **No `console.log`.** It can reshuffle the microtask queue and hide the bug (validated in session).
- **No adding React state.** It changes the render cycle.
- **No `setInterval` / `setTimeout` for measurement.** Timing-sensitive bugs become noisy.
- **Log points must never mutate business logic.** Read-only. No side effects.

## ✅ Do

- Mutable array push (synchronous storage)
- `performance.now()`-based `dt` (in ms)
- Standard schema `{scopeId, step, ...data}`
- Mix multiple instances in one array — filter by `scopeId` during analysis
