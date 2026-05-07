# Component test patterns (RTL + Vitest)

Load this file only when writing a Component-tier test. Component tests are exceptions, not the norm — they exist for orchestration hooks and repeatedly-regressing UI areas, not for routine UI.

## When a component test earns its keep

Per `frontend/claude-docs/TESTING.md`, write a component test only when:
1. The hook orchestrates store + query + side effect (e.g., subscribes to a stream and updates a store)
2. The component has a state machine or ≥3 conditional render branches
3. The component lives in a repeatedly-regressing area:
   - Zustand selector loops (memory: `feedback_zustand_array_selector`)
   - Konva multi-select drag (memory: `feedback_konva_transformer_drag`)
   - Trend Y-reset narrow zoom (memory: `project_trend_y_reset_fix`)

Otherwise → **Skip**.

## Pattern: orchestration hook with `renderHook`

Reference shape: `apps/customer-a/src/hooks/useSimulationOverlay.test.ts`.

Test the hook's **observable contract** (returned values, side effects on stores), not its internal call sequence.

```ts
import { renderHook, act } from '@testing-library/react';
import { describe, it, expect, beforeEach } from 'vitest';
import { useSimulationOverlay } from './useSimulationOverlay';
import { useSimulationStore } from '../store/simulationStore';

beforeEach(() => {
  useSimulationStore.getState().reset();
});

describe('useSimulationOverlay', () => {
  it('darkens the overlay when simulation enters playing state', () => {
    const { result } = renderHook(() => useSimulationOverlay());
    act(() => {
      useSimulationStore.getState().setStatus('playing');
    });
    expect(result.current.darkened).toBe(true);
  });

  it('cleans up subscription on unmount', () => {
    const { unmount } = renderHook(() => useSimulationOverlay());
    const before = useSimulationStore.getState().subscriberCount;
    unmount();
    expect(useSimulationStore.getState().subscriberCount).toBe(before - 1);
  });
});
```

## Pattern: state-machine component

Use RTL `render` + `userEvent`. Verify each transition once, not every internal render.

```ts
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

it('wizard advances step on Next click', async () => {
  const user = userEvent.setup();
  render(<AlarmAckWizard alarmId="a-1" />);
  expect(screen.getByText(/step 1/i)).toBeVisible();
  await user.click(screen.getByRole('button', { name: /next/i }));
  expect(screen.getByText(/step 2/i)).toBeVisible();
});
```

Selector priority: `getByRole` > `getByLabelText` > `getByText` > `getByTestId`. Avoid querying by class or DOM structure.

## Pattern: regression test for selector loop

If you fixed a "selector returning a new array on every render" bug, the regression test is in **Component tier** (because the bug only manifests through React's render cycle):

```ts
it('does not infinite-loop when consumed via hook', () => {
  let renderCount = 0;
  const Probe = () => {
    const items = useAlarmStore(useShallow((s) => s.selectActiveAlarms()));
    renderCount++;
    return <div>{items.length}</div>;
  };
  render(<Probe />);
  // If the selector returned a new ref each time, RTL's act would loop forever
  // and the test would time out; reaching this assertion proves stability.
  expect(renderCount).toBeLessThan(5);
});
```

## What NOT to test at this tier

- "Renders without crashing" — useless, just slow CI.
- Snapshot of large component output — brittle, encodes implementation.
- Pure prop-passing wrappers — no logic.
- Visual styling — that's Visual Capture's job (`pnpm pw:capture`).
- Trivial click handlers (`<button onClick={onClick}>`) — testing framework, not your code.

## Setup gotchas

- **Wrap with required Providers** (TQ, Service, Theme) only if the component depends on them. Use a small `renderWithProviders` helper colocated with the test.
- **MSW**: tests can rely on the project-wide MSW worker if needed; reset handlers in `beforeEach`.
- **Zustand**: always `reset()` stores in `beforeEach` to avoid cross-test bleed.
- **Cleanup**: RTL's `cleanup` runs automatically per test in modern Vitest setups.
