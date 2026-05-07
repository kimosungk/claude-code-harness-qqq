# Decision Rubric & Autonomy Tiers

Apply this rubric to every concrete tech decision. The output is one of three tiers — L1 (full autonomy), L2 (confirm autonomy), L3 (full escalation) — which determines whether you decide on your own, ask the user a single confirmation question, or run a full Socratic round.

## The 5-Axis Rubric

Score each candidate option 1-3 on each axis (1 = poor, 2 = acceptable, 3 = strong). Tie-breaking is qualitative — explain in the rationale, never invent numbers.

### 1. Maintainability

Does the option fit existing patterns in the repo? Does the next dev have to learn something new? Does it match the project's conventions (naming, file layout, test style)?

- **3** — Reuses an established pattern at `file:line`; matches naming/layout conventions verbatim.
- **2** — New surface but follows a known pattern from elsewhere in the repo.
- **1** — Introduces an unfamiliar pattern requiring documentation for future maintainers.

### 2. Performance

Measurable impact at expected load? Bundle size, render cost, request count, payload size, query plan.

- **3** — No measurable cost, or measurably better than alternatives at expected load.
- **2** — Acceptable cost; no headroom concern at current scale.
- **1** — Risk of perceptible regression for the user at expected load (back this up with numbers if possible).

### 3. Security

Auth, authz, input validation, secret handling, CSRF/XSS/SQLi posture, dependency-chain risk, data privacy.

- **3** — Strictly inherits or strengthens the repo's existing security posture.
- **2** — Neutral; introduces no new attack surface beyond what's already there.
- **1** — Adds a new attack surface or weakens existing posture; needs explicit mitigation.

### 4. Integration-Fit

How much existing code can be reused? How many integration points are touched? Does the option play with the codebase's existing assumptions about state ownership, error handling, transactions?

- **3** — Reuses existing services/stores/hooks; touches ≤2 integration points.
- **2** — Adds one new integration point; otherwise reuses.
- **1** — Replaces or duplicates existing infrastructure; touches >3 integration points.

### 5. Observability & Rollback

Can the change be observed in production (logs, metrics, traces)? Can it be rolled back cleanly if it goes wrong? This axis intentionally mirrors the Phase 2 critic gate's premortem (see `agents/code-plan-review-critic.md` and `skills/code-plan-review-critic/SKILL.md`) — pre-empting predictable critic rejections.

- **3** — Standard logging/metrics already cover this surface; rollback is a flag flip or revert-and-deploy.
- **2** — Minor instrumentation needed; rollback requires care but is well-understood.
- **1** — New surface with no observability story; rollback requires data migration or coordinated deployment.

### Plus: UX-Consequence Check (gate, not score)

Does the option violate any UX constraint frozen in `phase1-spec.md` (loading state, error message, empty state, latency expectation, accessibility)? This is a binary gate — if it violates, the option is **disqualified** unless an Amendment Gate clears the constraint. Never silently override.

**Quote, don't paraphrase**: when checking the gate, you MUST quote the exact text from `phase1-spec.md` that the option could violate, with section reference (e.g., §5.2). If you cannot find a specific phase1-spec.md line that the option would violate, the gate is clean — record "no violation found" in the evidence rationale. This anchors the self-administered check on external text and prevents circular reasoning.

## Autonomy Tiers

After scoring, classify the decision:

### L1 — Full Autonomy

**All** of:
- One option strictly dominates: scores ≥ all other options on every axis, AND scores > all other options on at least one axis.
- A repository pattern (or an authoritative external doc URL for new dependencies) supports the choice.
- The UX-consequence gate is clean.

**Action**: decide, document evidence + rationale, mark `Decided: Autonomously` in §1/§5 of the spec. No user prompt for this decision.

**Examples**:
- "Reuse existing `useQuery` pattern from `src/hooks/useTrend.ts:18` for the new alarm list" — repo pattern dominates, integration-fit and maintainability max.
- "Use `zod@3` (already in dependencies at `package.json:42`) for the new request schema" — no new dep, security and integration-fit max.

### L2 — Confirm Autonomy

**Either**:
- Top option dominates most axes (≥3 of 5) but a competing option has a real tradeoff on a remaining axis, OR
- Top option dominates all axes but the rationale relies on an assumption the user might want to validate.

**Action**: write the decision + rationale, then issue a **single** `AskUserQuestion`:

```
Question: "Lock <decision>? Rubric scoring: <top option> wins on <axes>; <competing option> better on <axis>."
Options:
- Confirm — proceed as proposed
- Discuss — promote to L3
- Other — free text
```

If Confirm → mark `Decided: With user (confirmed)`. If Discuss → run an L3 round.

**Example**:
- "Use Zustand for the new alarm-detail panel state (rubric: maintainability 3, integration-fit 3 vs Context API: integration-fit 2). Concern: Context might be enough for a 2-field slice. Confirm or discuss?"

### L3 — Full Escalation

**Any** of:
- Top two options score within 1 point on the dominant axes — genuinely tied.
- Evidence is thin: no repo pattern, no authoritative external doc, novel area.
- The UX-consequence gate is uncertain — there's a plausible reading where it violates.
- New dependency without clear ecosystem signal (low maintenance, license unclear, niche).

**Action**: run a Socratic round. Use `socratic-techniques.md` for question shapes. Land on a decision that can be locked.

After resolution, mark `Decided: With user (discussed)`.

## Library-Decision Sub-Protocol

When deciding a new dependency:

1. **Check existing**: grep `package.json` (or pyproject, Cargo.toml, etc.). If a package already in the dep tree covers ≥80% of needs, prefer it — score that option +1 on integration-fit.
2. **Query Context7 MCP** for authoritative library docs:
   ```
   mcp__plugin_context7_context7__resolve-library-id { libraryName: "<name>" }
   mcp__plugin_context7_context7__query-docs { libraryId: "<resolved>", query: "<specific feature>" }
   ```
3. **Check ecosystem signal** (use WebFetch for npm/PyPI/crates listing):
   - License compatibility with the project license
   - Last release date (>12 months → degrade maturity score)
   - Open-vs-closed issue ratio (red flag if >50% open critical)
   - Bundle size for frontend deps (bundlephobia)
4. **Evidence shape for new deps**: cite the resolved Context7 doc URL or the package registry URL — `file:line` is not applicable. Write the URL into the §1 New Dependencies table.

If step 2 (Context7) cannot resolve the library, do NOT auto-escalate to L3. Instead, default to **L2** with the package registry URL (npm / PyPI / crates / etc.) as the evidence — let the user confirm in a single round. Demote all the way to **L3** only when both Context7 AND the registry are unreachable, OR ecosystem signal in step 3 actively raises a red flag (license incompatibility, unmaintained package, niche fork). Excessive auto-L3 contradicts the autonomy mandate; the user-confirmation step is what L2 exists for.

## Worked Decision Walkthroughs

### Example A — Tech stack reuse (L1)

**Decision**: state management for the new alarm-history page.

Options scored:
- Reuse Zustand (already in repo, `src/store/alarmStore.ts:8`):
  - Maintainability 3, Performance 3, Security 3, Integration-fit 3, Observability 3 = 15
- Add Redux Toolkit:
  - Maintainability 1, Performance 3, Security 3, Integration-fit 1, Observability 2 = 10

Zustand strictly dominates. UX gate clean. → **L1**: decide, mark Autonomously.

### Example B — Validation library (L2)

**Decision**: request body validation for new API endpoint.

Options:
- Reuse `zod` (already in deps, used at `src/schemas/alarm.ts:12`): all-axis 3 except Performance 2 (zod parse cost on hot path).
- `valibot` (smaller, faster): Maintainability 1 (new), Integration-fit 1, Performance 3.

Zod dominates 4/5 axes; valibot wins Performance. The hot-path concern is plausible but speculative without a benchmark. → **L2**: propose Zod, single confirmation question with scoring summary.

### Example C — Real-time transport (L3)

**Decision**: how to push alarm updates to the client.

Options: WebSocket, SSE, polling. Repo has none of these. Tradeoffs:
- Latency: WS > SSE > polling
- Implementation complexity: WS > SSE > polling
- Observability: polling > SSE > WS (existing HTTP logging covers polling)
- Frozen-spec UX: spec says "real-time updates within 2s" — polling at 5s interval would violate

Tied on multiple axes; UX gate disqualifies one option. → **L3**: full Socratic round to surface user's tolerance for complexity vs latency.

## Anti-Patterns

- Inflating L1 to skip user interaction — if you score yourself confidently on three options you generated, it's likely L2.
- Demoting to L3 to avoid taking a position — if the rubric clearly dominates and evidence is solid, decide. Document the rationale; the user reviews at Phase 5.
- Re-litigating frozen `phase1-spec.md` UX as "tech tradeoff" — that's an Amendment Gate trigger, not a rubric axis.
- Citing a vague "best practice" instead of `file:line` or doc URL — best practices without evidence are guesses.
