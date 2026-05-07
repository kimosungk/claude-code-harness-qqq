# Unit test patterns (Vitest)

Load this file only when writing a Unit-tier test. Skip and Component/E2E tasks do not need it.

## Vitest config (canonical)

- Single config: `apps/customer-a/vite.config.ts` (the `test:` block at the bottom)
- `environment: 'jsdom'`
- `setupFiles: ['vitest.setup.ts']`
- Test files are colocated: `apps/customer-a/src/**/*.test.ts(x)`, `packages/**/src/**/*.test.ts(x)`
- Run from repo root: `pnpm test` (runs all) or `pnpm test <path>` (single file)

## Pattern: Zod schema test

Sibling reference: `packages/@core/api/src/schemas/auth.test.ts`, `model.test.ts`

Verify both **happy path** (valid input parses) and **boundary failures** (invalid → throws or returns issues). Do not test internal Zod mechanics.

```ts
import { describe, it, expect } from 'vitest';
import { alarmResponseSchema } from './alarm';

describe('alarmResponseSchema', () => {
  it('parses a well-formed response', () => {
    const valid = { id: 'a-1', severity: 'high', timestamp: '2026-04-28T00:00:00Z' };
    expect(() => alarmResponseSchema.parse(valid)).not.toThrow();
  });

  it('rejects missing required field', () => {
    const invalid = { id: 'a-1' }; // no severity
    expect(() => alarmResponseSchema.parse(invalid)).toThrow();
  });

  it('rejects out-of-range severity', () => {
    expect(() =>
      alarmResponseSchema.parse({ id: 'a-1', severity: 'unknown', timestamp: '...' })
    ).toThrow();
  });
});
```

## Pattern: Zustand store action with branching

Reset store between tests via the store's own `reset()` action (project convention).

```ts
import { beforeEach, describe, it, expect } from 'vitest';
import { useTrendStore } from './trendStore';

describe('useTrendStore.setRangeWithClamp', () => {
  beforeEach(() => {
    useTrendStore.getState().reset();
  });

  it('clamps when start > end', () => {
    useTrendStore.getState().setRangeWithClamp({ start: 100, end: 50 });
    expect(useTrendStore.getState().range).toEqual({ start: 50, end: 100 });
  });

  it('keeps order when valid', () => {
    useTrendStore.getState().setRangeWithClamp({ start: 10, end: 20 });
    expect(useTrendStore.getState().range).toEqual({ start: 10, end: 20 });
  });
});
```

## Pattern: selector with derivation

The repeating regression: a selector returning a fresh array (`.filter`, `.map`) on each call causes infinite re-renders when consumed via `useStore(selector)`. Tests must verify **referential stability** when source state is unchanged.

```ts
it('returns the same reference when input is unchanged', () => {
  const a = useAlarmStore.getState().selectActiveAlarms();
  const b = useAlarmStore.getState().selectActiveAlarms();
  expect(a).toBe(b); // referential — not toEqual
});
```

If your selector uses `useShallow` or memoization, this is the test that protects it.

## Pattern: pure utility

Reference: `packages/ui-charts/src/xCoordReady.test.ts`, `thresholdStagger.test.ts`.

Just input → output. No mocks, no setup beyond imports.

```ts
describe('formatTimestamp', () => {
  it.each([
    [0, '1970-01-01T00:00:00Z'],
    [1700000000000, '2023-11-14T22:13:20Z'],
  ])('formats %i correctly', (input, expected) => {
    expect(formatTimestamp(input)).toBe(expected);
  });
});
```

## Skip these in Unit tests

- TQ hook bindings that just wrap `useQuery({ queryKey, queryFn })` with no logic — binding is self-evident
- Trivial setters: `setX: (x) => set({ x })`
- React component rendering (use Component tier or Skip entirely)
- Network calls (use MSW or skip — Unit tier should be fast and deterministic)

## Common gotchas

- **`getState()` vs hook subscription**: in unit tests, prefer `useStore.getState()` — you're not testing React subscription, you're testing state transitions.
- **Async actions**: use `await` on the action; do not use `act()` unless you're rendering React.
- **Cross-store side effects**: if action A in store X also touches store Y, test the cross-store invariant explicitly. (See memory `feedback_model_sensor_symmetry`.)
- **Date/time**: stub `Date.now` with `vi.setSystemTime` if the action uses time.
