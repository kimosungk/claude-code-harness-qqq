# E2E test patterns (Playwright)

Load this file only when writing an E2E test. Most changes do **not** need a new E2E — the rule is "1 happy path per money flow, plus repeatedly-regressing areas".

## Project layout

- Config: `apps/customer-a/playwright.config.ts`
- Tests: `apps/customer-a/e2e/tests/*.spec.ts`
- Captures (visual): `apps/customer-a/e2e/capture/*.capture.ts` — different purpose, do NOT extend
- Page Objects: `apps/customer-a/e2e/pages/*.page.ts` — `alarm.page.ts`, `dashboard.page.ts`, `login.page.ts`, `trend.page.ts`
- Fixtures: `apps/customer-a/e2e/fixtures/base.fixture.ts`, `capture.fixture.ts`, `canvas-seed.ts`
- Auth state: `apps/customer-a/e2e/.auth/user.json` (created by `global-setup.ts`)

## Critical environment fact

E2E runs against the **real backend** at `172.31.33.168` with `VITE_USE_MOCK=false` (see `playwright.config.ts:62`). This has consequences:

- Real credentials, real auth flow
- `workers: 1, fullyParallel: false` — tests run serially
- Data must be created and torn down (no rollback) — see canvas-seed pattern below
- Network must reach the backend; tests fail offline

Do NOT write E2E that assumes mock data shape — those are Unit/Component territory.

## Pattern: use POM, not raw locators

Reference: `apps/customer-a/e2e/tests/canvas-drag.spec.ts` and the POMs under `pages/`.

```ts
import { test, expect } from '../fixtures/base.fixture';
import { DashboardPage } from '../pages/dashboard.page';

test('dashboard shows alarm count after creation', async ({ page }) => {
  const dashboard = new DashboardPage(page);
  await dashboard.goto();
  await dashboard.expectAlarmCount(3);
});
```

If a POM method does not exist for the action you need, **add it to the POM** (one PR, one method). Do not call `page.locator(...)` from the spec body. POM methods are the contract; raw locators leak implementation.

## Pattern: seed test data on real backend

Reference: `apps/customer-a/e2e/fixtures/canvas-seed.ts` + `canvas-drag.spec.ts`.

The seed helper creates data via real API calls in `beforeAll`, returns the IDs the spec needs, and the spec tears down in `afterAll`. **Always tear down**, even on failure.

```ts
import { test, expect } from '../fixtures/base.fixture';
import { seedTestCanvas, deleteTestCanvas, type SeedResult } from '../fixtures/canvas-seed';

test.describe('canvas drag', () => {
  let seed: SeedResult;

  test.beforeAll(async ({ request }) => {
    seed = await seedTestCanvas(request);
  });

  test.afterAll(async ({ request }) => {
    await deleteTestCanvas(request, seed.canvasId);
  });

  test('moves widget to new position', async ({ page }) => {
    // ... use seed.canvasId, seed.widgetIds
  });
});
```

## `window.__e2e` — last-resort store access (gated by 3-question check)

⚠️ **Reaching into Zustand internals from an E2E spec is an anti-pattern by default** — it's implementation coupling, the very thing tests should avoid. Each `window.__e2e` use bets that the store shape will not change without you noticing.

**Before writing any line that touches `window.__e2e`, answer all three:**

1. Can the same fact be observed via DOM (rendered count, visible label, ARIA attribute, screenshot region)? If **yes**, do that instead — close this section.
2. Is the test verifying user-visible behavior, or framework state? E2E exists for the former — if the answer is "framework state", consider whether this belongs at Component or Unit tier instead.
3. Will this assertion break on a non-buggy refactor of the store (e.g., a field rename)? If **yes**, it mirrors implementation — re-think; the test should not exist.

If and only if all three gates pass (typically: a side effect that intentionally has no UI surface), the syntax is:

```ts
const widgetCount = await page.evaluate(() => {
  // @ts-expect-error - injected in DEV/Mock builds
  return window.__e2e.canvasStore.getState().widgets.length;
});
expect(widgetCount).toBe(3);
```

Stores currently exposed: `canvasStore`, `canvasUIStore`. Exposed when `import.meta.env.DEV || IS_MOCK` (per `apps/customer-a/src/index.tsx:72`). Treat any new addition to `window.__e2e` as raising the bar — the more you couple, the more refactors will break specs.

## Pattern: 1 happy path per money flow

Money flows: login, primary CRUD on canvas, alarm acknowledge, trend export, simulation playback. Each gets exactly **one** E2E test that walks the happy path. Negative paths and edge cases belong in Unit/Component tier.

If a money flow has no E2E yet, that's the first thing to add. If it already has one, do not write a second variation — extend the POM if a sub-step needs coverage.

## What NOT to E2E

- Anything Unit/Component already covers — duplication is forbidden.
- Mock-only behavior — there are no mock-only specs in this codebase; if you genuinely need one, mark it `test.describe.skip` with a TODO and rewrite as Unit instead.
- UI minutiae (dropdown opens, hover states) — Component tier or Visual Capture.
- Multiple variations of the same flow — pick the canonical happy path.

## Common gotchas

- `timeout: 120_000` is the per-test cap. If your test approaches it, the test is wrong (probably waiting on something flaky).
- `screenshot: 'only-on-failure'` — leave it; do not add manual screenshots.
- `trace: 'on-first-retry'` — useful for debugging; check `playwright-report/`.
- Authentication: `storageState: 'e2e/.auth/user.json'` is loaded automatically; do not log in inside specs.
- If a test is flaky, the underlying behavior is flaky. Do not paper over with retries — fix root cause or Skip.

## Running

- All E2E: `pnpm pw:e2e`
- Single test: `pnpm pw:e2e --grep "<test name>"`
- UI debugger: `pnpm pw:e2e:ui`
- Report: `pnpm pw:report` (after a run)
