# Skip justification template

Load this when the 3-question gate or decision table indicates **Skip**. A Skip report is valuable output — it documents the policy decision so the caller does not re-ask the same question later.

## Template

```
SKIP — <one-line reason>

Decision table row: <row name verbatim from the table>
3-question gate:
  Q1 (production surface): <how would the bug manifest?>
  Q2 (other tier covers?): <yes + which test/file> | <no — and why no test is the right answer>
  Q3 (mirrors impl?): <yes — explanation> | <no>

No test file written.
Recommendation: <optional follow-up; omit if nothing useful to add>
```

Keep it under 15 lines. The reader is the calling Claude session, which needs a defensible decision, not a treatise.

## Worked examples

### Example 1 — trivial setter

```
SKIP — store action is a trivial setter

Decision table row: Store action = trivial setter (`set({ x })`)
3-question gate:
  Q1 (production surface): no derivation; bug would only occur if React itself failed to re-render, which is framework concern
  Q2 (other tier covers?): no — and no test is needed; the binding is self-evident
  Q3 (mirrors impl?): yes — any test would just re-state `set({ selectedAlarmId: id })` against itself

No test file written.
Recommendation: if this setter ever gains validation/clamp/derivation logic, that change qualifies for a Unit test under "Store action with branching/derivation".
```

### Example 2 — TQ hook is a thin wrapper

```
SKIP — TQ hook = simple fetch wrapper

Decision table row: TQ hook = simple fetch wrapper
3-question gate:
  Q1 (production surface): a wiring bug would surface in E2E money-path; queryKey is plain
  Q2 (other tier covers?): yes — the existing E2E `apps/customer-a/e2e/tests/dashboard.spec.ts` exercises this fetch via the dashboard load
  Q3 (mirrors impl?): yes — testing queryKey + queryFn against the same definition is tautological

No test file written.
```

### Example 3 — UI is presentational

```
SKIP — presentational component, no branching

Decision table row: UI component = presentational
3-question gate:
  Q1 (production surface): visual only; broken layout/style is caught by Visual Capture
  Q2 (other tier covers?): yes — `apps/customer-a/e2e/capture/dashboard.capture.ts` snapshots this surface
  Q3 (mirrors impl?): yes — any RTL render assertion would just re-state JSX

No test file written.
Recommendation: re-run `pnpm pw:capture` after the change and review diff visually.
```

### Example 4 — Skip but caller insisted

```
SKIP (with caller-override note) — change does not match any Required/Recommended row

Decision table row: <closest row, e.g., "UI component = presentational">
3-question gate:
  Q1: ...
  Q2: ...
  Q3: yes — mirrors implementation

No test file written.
Caller-override note: the user explicitly requested a test. Per agent protocol, Skip-first wins unless a real bug class is identified. To override, supply a contract clause that would actually be falsifiable by a test — currently none provided.
```

## What does NOT belong in a Skip report

- Apologies ("sorry, no test")
- Hedging ("we could maybe add a small test if you really want")
- Implementation peeking ("I noticed in the impl that…")
- Promises about future work — that's the calling session's job

The Skip report is a final, defensible decision. Move on.
