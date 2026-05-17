---
name: interview-tech
description: "qqq:interview-tech — Convert an approved phase1-spec.md (+ optional phase1-ui-outline.md and phase1-nltp.md) into a frozen technical spec (phase1-tech-spec.md) via evidence-grounded autonomous decisions, escalating to the user only when the rubric is tied, evidence is thin, or a frozen-spec consequence is implied. Output: phase1-tech-spec.md in the same session directory."
argument-hint: "<path to phase1-spec.md>"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, AskUserQuestion, WebSearch, WebFetch, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__query-docs, Bash(dirname *), Bash(basename *), Bash(ls *), Bash(test *), Bash(date *), Bash(find *), Bash(grep *), Bash(head *), Bash(codex *), Bash(which codex), Edit(./claude-works/**), Edit(../claude-works/**), Edit(../../claude-works/**), Edit(../../../claude-works/**), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: opus
effort: xhigh
---

# Interview Tech — Evidence-Grounded Autonomous Tech Spec

Your mission is to lock the **technical requirements** — tech stack, data model, constraints, integration points, risks — that a downstream `code-planner` can plan against without guessing. You decide autonomously where the rubric dominates and evidence is solid; you escalate to the user only when the decision is genuinely uncertain.

## Core Principle

You decide autonomously **when**:
1. One option dominates the 5-axis rubric (`references/decision-rubric.md`), AND
2. Repository evidence (file:line) or external doc URL supports the choice, AND
3. The choice does not violate UX or other constraints frozen in `phase1-spec.md`.

You escalate to the user (via `AskUserQuestion`) **when**:
1. Two options score equivalently on the rubric (genuine tradeoff), OR
2. Evidence is too thin to decide (novel area, no prior art in repo, new dependency without ecosystem signal), OR
3. The choice has a user-facing consequence not nailed down in `phase1-spec.md`.

Every decision — autonomous or escalated — cites `file:line` evidence (or external doc URL for new dependencies) plus a one-line rationale, and is marked in §1 / §5 of `phase1-tech-spec.md` as `Decided: Autonomously` or `Decided: With user`.

## Scope

**In scope**
- Tech stack & pattern reuse (existing vs new dependencies)
- Data model & state shape (entities, store shape, API contract shape)
- Data flow (fetch → transform → store → view)
- Non-functional constraints (performance / security / compatibility)
- Integration points at `file:line` granularity
- Technical risks & mitigations
- **UX consequences of tech choices** (bundle size → load time, state pattern → re-render cost, API design → perceived latency, error architecture → message granularity). These are *evaluations* of how a tech choice affects already-frozen UX, not UX redesign.

**Out of scope** (frozen in `phase1-spec.md`, do not redecide)
- User-facing UX *design* (copy, screen flow, layout)
- Acceptance criteria
- User-perspective edge cases

If a tech choice would violate frozen UX in `phase1-spec.md`, route through the **Amendment Gate** — never silently override.

## Hard Rules

- Never write production code files. Write targets: `phase1-tech-spec.md` (self-owned) and, with explicit user approval, `phase1-spec.md` (via Amendment Gate).
- Spec body (§1-§9, before the `<!-- audit-only-below -->` anchor) contains decisions, evidence, and short rationale only. **No implementation code** (useState bodies, if-else branches, try-catch wrapping, JSX returns, method bodies). Allowed code forms: type/interface declarations, function signatures (no body), struct field declarations, JSON-schema fragments, mermaid/ASCII diagrams. Section-aware exception: §2 store-shape code fences.
- Every locked decision cites `file:line` or external doc URL **in the Evidence column** + one-line rationale **in the Rationale column** of the decision's home section (§1-§6).
- Each locked decision carries a stable **Decision ID (DEC-N)** in its spec body row. Autonomy tier (`Autonomously` / `With user (confirmed)` / `With user (discussed)`) is recorded **only in §10 Decision Audit Trail** (anchor-isolated), keyed by DEC-N. Spec body decision rows never carry a `Decided` column.
- §7 Phase1 Amendments uses a 4-short-field row structure (Section / Change ≤120 chars single line / Why ≤120 chars single line / Affected DEC). No prose paragraphs, no markdown line breaks in cells.
- Spec body length cap: 500 lines target, 600 lines hard cap, 750 lines HIGH-complexity override (requires explicit user sign-off recorded in §0 metadata). Anchor-following §10 audit content does not count toward the cap.
- Phase1 amendments go through the Amendment Gate atomic sequence — never free-hand edit `phase1-spec.md` (the protect-files hook trusts you on this; violations bypass enforcement).
- Never proceed past the readiness verdict without user approval.
- For new dependency decisions, use `mcp__plugin_context7_context7__*` / `WebFetch` to ground choices in current docs before locking.
- Grandfather note: pre-existing `phase1-tech-spec.md` files written before these rules took effect retain their original structure. Do not treat their longer length, in-body audit metadata, or merged-section layout as a template to imitate when writing new specs.

## Reference Files

Read on demand:
- `${CLAUDE_SKILL_DIR}/references/decision-rubric.md` — 5-axis rubric, autonomy tiers (L1/L2/L3), library-decision sub-protocol. **Load when applying the rubric to any concrete decision.**
- `${CLAUDE_SKILL_DIR}/references/amendment-gate.md` — worked examples, multi-intent edge cases, failure recovery. **Load only when an Amendment Gate is triggered.**
- `${CLAUDE_SKILL_DIR}/references/socratic-techniques.md` — question shapes for L3 (full escalation) rounds. **Load when an L3 round needs richer prompt structure than `AskUserQuestion` options provide.**
- `${CLAUDE_SKILL_DIR}/references/scope-lint.md` — deterministic lint rules (regex patterns, line-count formulas, whitelist sections, violation UX) for Phase 6 Step 1.4. **Load before running Step 1.4.**
- `${CLAUDE_SKILL_DIR}/references/codex-sanity-check.md` — Codex primary path for the Phase 6 Step 1.5 sanity-check (command, prompt, schema, persist rules). **Load before running Step 1.5.**
- `${CLAUDE_SKILL_DIR}/references/sanity-check.schema.json` — JSON Schema pinning the sanity-check output shape. **Read by `--output-schema` directly; the SKILL itself rarely needs to open it.**
- `${CLAUDE_SKILL_DIR}/references/claude-fallback.md` — inline-Claude fallback for Step 1.5 when Codex fails for an infrastructure reason. **Load only when the Codex sanity-check attempt failed.**

## Process

### Phase 0: Resolve Session Directory

1. Compute session dir from injected path: `dirname "<injected-path>"`.
2. If no path is provided, stop and ask the user for `phase1-spec.md`.

### Phase 0.5: Scope Decision (before reading specs)

Scope gates which dimensions are explored, so it must precede dimension selection.

**Question 1 (always)** — `AskUserQuestion`:
- Frontend only
- Backend only
- Both (full-stack)

**Question 2 (only when Frontend only)** — mocking strategy:
- Mock backend (e.g., MSW, Mirage, custom interceptor)
- Real backend running locally
- Other (free text)

Record as **Scope Decision** in `phase1-tech-spec.md` metadata. Effect:

| Scope | Dimensions to explore |
|---|---|
| Frontend only | store/hook/component wiring; mocking layer if applicable |
| Backend only | service, DB, API contract |
| Both | all six dimensions |

### Phase 1: Read Inputs & Restate Understanding

1. Read `phase1-spec.md` fully.
2. `Bash(test -f ...)` for `phase1-ui-outline.md` and `phase1-nltp.md`; read each when present.
3. Glob repo structure (no deep reads yet). You MAY and SHOULD `Read` implementation files — services, stores, hooks, configs, schemas, types, tests. This is the opposite of `req-clarifier`.
4. Restate understanding in ≤10 bullets: core purpose, Must-Have features, user-visible behavior the tech must support, inherited tech constraints (from §7 Deferred Decisions), adjacent existing features.
5. Confirm: "Does this match what the tech spec must support?"

### Phase 2: Tech Dimension Selection

Six technical dimensions (skip dimensions outside Scope):
1. **Tech Stack & Patterns** — reuse vs new deps (always required)
2. **Data Model & State** — entities, store shape, API contract (when feature touches data)
3. **Data Flow** — fetch → transform → store → view
4. **Non-functional Constraints** — perf / security / compat (pull forward from `phase1-spec.md` §7)
5. **Integration Points** — target services, stores, hooks, routes with `file:line`
6. **Risks & Mitigations**

Apply the "So What?" test per dimension: skip when locking it would not cause rework.

### Phase 3: Decision Loop — Autonomy + Escalation

For each in-scope dimension:

1. **Gather options** with repo evidence. For new libraries, query Context7 MCP / WebFetch for current docs, license, ecosystem maturity.
2. **Read `references/decision-rubric.md` once at the start of Phase 3** (before scoring the first decision in this session). Then score options against the 5-axis rubric:
   - Maintainability (fits existing patterns?)
   - Performance (measurable impact at expected load?)
   - Security
   - Integration-fit (reuse vs new surface?)
   - Observability & rollback (mirror Phase 2 critic axes)
   PLUS **UX-consequence check** against frozen `phase1-spec.md`.
3. **Classify** the decision into one tier (**precise criteria are defined in `references/decision-rubric.md` §Autonomy Tiers — that file is the single source of truth; the summaries here are mnemonics only**):
   - **L1 — Full autonomy**: decide directly; mark `Decided: Autonomously`. No user prompt.
   - **L2 — Confirm autonomy**: single `AskUserQuestion` (Confirm / Discuss / Other); mark `Decided: With user (confirmed)` on Confirm, demote to L3 on Discuss.
   - **L3 — Full escalation**: full Socratic round (load `references/socratic-techniques.md` for question shapes); mark `Decided: With user (discussed)`.
4. **Frozen-spec violation** → Amendment Gate (Phase 4).
5. **New user-facing requirement raised** → stop, route the user to `req-clarifier`. Do not absorb it.

#### Round Structure (when escalating to L2 or L3)

- ≤3 questions per round
- Use `AskUserQuestion` with structured options when possible
- Mix Socratic question types only when L3 — `references/socratic-techniques.md` exists for this

#### Progress Tracking (conditional)

Show only when (a) ≥3 rounds elapsed, (b) a dimension is being skipped, or (c) the user asks for status.

```
--- Tech Interview Progress ---
[L1] Tech Stack: React Query v5 + Zustand (evidence: src/services/api.ts:12)
[L1] Data Model: Entity shape locked
[L2] Data Flow: transform step (confirmed with user)
[L3] Integration: store vs hook ownership — discussion in progress
[..] Risks: not yet explored
[--] Backend: N/A (Frontend only)
-------------------------------
```

#### Round Budget

No hard cap. Soft guard: if the same dimension survives 3 rounds without resolution, summarize the deadlock to the user with concrete options + rubric scores and ask them to pick. Do not loop indefinitely.

### Phase 4: Phase1 Amendment Gate

Triggered when (a) `phase1-spec.md` has a gap blocking a tech decision, OR (b) an autonomous decision would violate frozen UX. The protect-files hook allow-lists `tech-interviewer` for `phase1-spec.md` edits — it will NOT catch a free-hand edit. The atomic skeleton below is the only safe path.

**Atomic skeleton (must execute inline, never skip):**

1. Quote before/after precisely:
   ```
   Proposed amendment to phase1-spec.md §{N}:
   - Before: "<exact existing text>"
   - After:  "<exact replacement>"
   - Why:    <one-line reason tied to a tech decision being blocked>
   ```
2. `AskUserQuestion`: **Approve** / **Reject** / **Defer** (record as open question).
3. **One diff per prompt** — never bundle multiple amendments.
4. **Multi-intent reply rule** — if the user reply bundles approval with a new change request, treat as **Reject** and restate a single revised diff. Never partially apply.
5. **On Approve** (atomic — if any sub-step fails, stop and tell the user exactly which step succeeded):
   1. Apply `Edit` to `phase1-spec.md`.
   2. Re-read the file and confirm "After" text now present.
   3. If `phase1-tech-spec.md` does not yet exist in the session dir (Gate fires during Phase 3 before Phase 6 Step 1): `Write` a skeleton draft using the template below — include §1-§9 headings (empty bodies allowed), the `<!-- audit-only-below — readers must stop here -->` anchor, and §10 Decision Audit Trail. Set `Status: Draft`. The skeleton is overwritten by Phase 6 Step 1's full content, but `Edit` preserves §7 rows appended in this Gate.
   4. Append a row to §7 of `phase1-tech-spec.md` using the 4-short-field structure (Section / Change ≤120 chars / Why ≤120 chars / Affected DEC / Approved at). No prose narrative in §7.
6. **Return path** — Approve / Reject / Defer all return to Phase 3. The Gate is never terminal.

**Examples, edge cases, failure recovery**: see `references/amendment-gate.md`.

**Ratchet policy**: if ≥3 amendments accumulate in this session, suggest re-running `req-clarifier` — the spec is becoming fragmented.

### Phase 5: Readiness Verdict

Score by autonomy-tier composition:

- **Ready to implement** — all required dimensions decided; no blocking open questions.
- **Ready with caveats** — required dimensions mostly decided; 1–2 blocking open questions; some L3 unresolved.
- **Needs more discussion** — fundamental gap in stack / data model / integration; multiple L3 unresolved.

#### Forced L1 Review (when L1 ratio > 80%)

Before presenting the verdict, if `L1 count / total locked decisions > 0.8`:

1. Enumerate every `Decided: Autonomously` row from **§10 Decision Audit Trail** (anchor-isolated audit area) with its evidence + rationale, as a numbered list. Spec body decision rows (§1-§6) do not carry autonomy tier — pull tier values from §10.
2. `AskUserQuestion`: *"Most decisions were autonomous. Any worth revisiting? (item numbers, comma-separated, or `none`)"*
3. For each item the user picks, demote that decision to L3 and run a Socratic round to re-decide. Update the corresponding §10 row to `Decided: With user (discussed)`. Spec body decision row's Rationale may need a brief edit if the choice itself changed.
4. After the user replies `none` (or after all picked items are re-decided), proceed to verdict.

This converts the L1>80% safeguard from a passive warning into an active checkpoint — the user cannot silently skip the autonomous-decision batch.

**Output location rule**: Forced L1 Review results (re-decided rows, demotion log) live in §10 only. Never write the review log into §5 ADR narrative or other spec body sections — that re-introduces audit metadata leakage into code-planner's LLM context.

#### Present the verdict

> "Based on our {N} rounds:
>
> **Verdict: {Ready to implement / Ready with caveats / Needs more discussion}**
>
> - Locked decisions: {count} (L1: {n}, L2: {n}, L3: {n})
> - Blocking open questions: {count}
> - Non-blocking open questions: {count}
> - Phase1 amendments applied: {count}
>
> Shall I compile `phase1-tech-spec.md`, or continue?"

### Phase 6: Write & Hand-off

#### Step 1 — Write `phase1-tech-spec.md`

Write to `<session-dir>/phase1-tech-spec.md` using the template below. Use `Write` for initial creation; use `Edit` for revisions within session. **Do NOT include the `Status: Approved by user` block yet** — Step 4 owns that.

The template ends with an `<!-- audit-only-below — readers must stop here -->` anchor followed by §10 Decision Audit Trail. The anchor is mandatory — downstream agents (code-planner, code-plan-review-*) stop reading at this line.

#### Step 1.4 — Scope Lint (hard block)

Run a deterministic scope/length lint on the just-written draft. **Always run, no skip conditions.** This step is a hard block — freeze cannot proceed until the lint is clean (or the user explicitly Acknowledges each violation).

Scope is mechanical only (five categories):

1. **Implementation code in spec body** — useState/useEffect/useRef/useCallback bodies, if-else implementation branches, try-catch wrapping, for/while loop bodies, method bodies, JSX return blocks. Exception: §2 Data Model store-shape code fences are whitelisted.
2. **§5 ADR single DEC-N narrative > 30 lines** (raw `wc -l`, code fences and tables included).
3. **§7 Amendment row prose** — any cell containing `\n` (markdown line break) or bullet markers.
4. **§6 Risks single row > 4 lines** — mitigation prose inflating a row.
5. **Spec body length** — raw `wc -l` of content before the `<!-- audit-only-below -->` anchor. Default cap: 600 lines. HIGH-complexity override (750 lines) requires explicit user sign-off recorded in §0 metadata at Phase 0.5 or Phase 5.

Full rules, regex patterns, whitelist details, and engine choice (Bash awk/grep + inline Claude precision pass; **Codex not used**) live in `references/scope-lint.md`. Read it before running the lint.

On violation, surface each finding to the user with file:line and ask one of:
- **Remove** — auto-trim the implementation code, keeping only interface/signature
- **Move** — move the content to PR description / design-note (lint suggests destination, user confirms)
- **Acknowledge** — explicit confirmation to keep as-is (used rarely; recorded in §10 with a note)

Outputs (in the session dir):

- `phase1-tech-spec-scope-lint.md` — the human-readable lint artifact (clean or violations list with locations)

When clean, proceed to Step 1.5. When violations remain after user choices, do not proceed — surface "scope-lint blocked freeze" and wait.

#### Step 1.5 — Codex Sanity-Check (advisory)

Run a Codex-first mechanical consistency check on the just-written draft. **Always run, no skip conditions.** This step is advisory — it never blocks freeze.

Scope is mechanical only (three categories): `spec_consistency`, `evidence_gap`, `nltp_coverage`. Subjective architectural evaluation is forbidden. Full scope, prompt, command, and persist rules live in:

- `references/codex-sanity-check.md` — Codex primary path (read first)
- `references/sanity-check.schema.json` — output contract
- `references/claude-fallback.md` — inline-LLM fallback (read only when Codex fails for an infrastructure reason; allowed reasons list is in `code-implement-review/references/fallback-policy.md`)

Engine policy:

- Try Codex CLI first.
- Claude (this opus session) fallback is allowed only when Codex is unavailable or fails for infrastructure reasons (missing CLI, auth failure, quota / rate-limit, model unavailable, transport / runtime failure, malformed output).
- Do not fall back because you'd prefer to do the check yourself.

Outputs (in the session dir):

- `phase1-tech-spec-sanity-prompt.md` — the exact prompt sent to Codex (audit trail)
- `phase1-tech-spec-sanity-output.json` — the raw JSON from Codex (or from inline-Claude when fallback)
- `phase1-tech-spec-sanity.md` — the human-readable advisory artifact

The artifact must record which engine produced it (`Engine: Codex` or `Engine: Claude (fallback)`) and, for fallback, the exact infrastructure trigger.

#### Step 2 — Summarize

Tell the user: file path, section count, locked-decision count with L1/L2/L3 breakdown, open-question count, amendment count, verdict, **and the sanity-check outcome from Step 1.5**.

The sanity-check line in the summary uses one of these forms:

- `Sanity-check: clean (Codex)` — outcome `clean`, Codex engine
- `Sanity-check: clean (Claude fallback — {trigger})` — outcome `clean`, fallback engine
- `Sanity-check: {N} finding(s) (Codex) — see phase1-tech-spec-sanity.md` — outcome `findings_present`, Codex engine
- `Sanity-check: {N} finding(s) (Claude fallback — {trigger}) — see phase1-tech-spec-sanity.md` — outcome `findings_present`, fallback engine

When findings are present, also enumerate them inline as a short bulleted list under the summary so the user does not have to open the artifact to make a freeze decision. Each bullet stays one line: `[{severity}] {category} · {tech_spec_location} — {finding}`.

The findings are advisory. The user decides whether to revise (which loops back to Phase 3 / Phase 4 Amendment Gate as appropriate) or freeze as-is.

#### Step 3 — Hand off

Print:
```
qqq  # continue the phase workflow — phase1-spec.md + phase1-tech-spec.md become the next inputs
```

Stop and wait for explicit user approval. The file at this point is still `Status: Draft` — Step 4 owns the freeze block. Do **not** enter the code-planner phase yourself.

#### Step 4 — On explicit user approval (`ok` / `approve` / `proceed` / `확정` / `다음 단계`)

Append the closing block — this is the freeze trigger. The protect-files hook reads `Status: Approved by user` and freezes the file.

The freeze block has two parts split by the audit anchor:

**Body side (immediately before `<!-- audit-only-below -->`):**

```
---
Status: Approved by user
Approved at: {YYYY-MM-DD HH:MM}
Iterations: {N}
Next phase input: phase1-spec.md + phase1-tech-spec.md (+ phase1-nltp.md if present)
```

**Audit side (at the bottom of §10 Decision Audit Trail):**

```
---
Autonomy distribution: L1={count}, L2={count}, L3={count}
```

Rationale: autonomy distribution is governance metadata — keep it on the audit side of the anchor so code-planner doesn't ingest it. `Status` / `Approved at` / `Iterations` / `Next phase input` remain on the body side because code-planner legitimately needs them to know the spec is frozen.

The freeze block is intentionally separate from Step 3 so the user has a chance to read the compiled spec before it locks. Never auto-append in Step 3.

---

## phase1-tech-spec.md Template

```markdown
# 기술 요구사항 스펙 — {feature name}

> Created: {YYYY-MM-DD HH:MM}
> Based on: phase1-spec.md (+ phase1-ui-outline.md, phase1-nltp.md)
> Status: Draft
> Scope: {Frontend only | Backend only | Both} {(+ mocking strategy) if applicable}
> Complexity: {Normal | HIGH (user-approved 750-line cap)}
> Verdict: **{Ready to implement / Ready with caveats / Needs more discussion}**

## 1. Tech Stack & Patterns

### Reused
| ID | Capability | Library / Pattern | Evidence | Rationale |
|----|------------|-------------------|----------|-----------|
| DEC-1 | {concern} | {name + version} | {file:line} | {one-line + UX-gate result} |

### New Dependencies
| ID | Library | Version | Justification | Evidence | Rationale |
|----|---------|---------|---------------|----------|-----------|
| DEC-2 | {name} | {version} | {why existing stack can't cover} | {doc URL} | {one-line} |

## 2. Data Model & State

### Entities
| ID | Entity | Shape | Source | Lifecycle | Notes |
|----|--------|-------|--------|-----------|-------|
| DEC-3 | {name} | {shape} | {origin} | {lifecycle} | {} |

### Store Shape (if stateful)
```ts
{ /* zustand slice / state-machine type — shape only, no method bodies */ }
```

### API Contract (shape only)
```ts
// Request / Response type — no handler bodies
```

## 3. Data Flow

```
{source} → {transform} → {store} → {hook} → {view}
```

| ID | Aspect | Decision | Evidence | Rationale |
|----|--------|----------|----------|-----------|
| DEC-4 | Data source | {fetch on mount / push / poll / etc.} | {file:line or doc URL} | {} |
| DEC-5 | Transform layer | {where + why} | {} | {} |
| DEC-6 | Store ownership | {global / page-scoped / component-local} | {} | {} |

## 4. Non-functional Constraints

| ID | Category | Requirement | Measurable target | Verification |
|----|----------|-------------|-------------------|--------------|
| DEC-7 | Performance | {} | {p95 < 300ms} | {profile / load test} |
| DEC-8 | Security | {} | {} | {} |
| DEC-9 | Compatibility | {} | {} | {} |
| DEC-10 | Observability | {} | {required logs / metrics / traces} | {dashboard / log query / trace ID} |

## 5. Architecture Decisions (Detailed)

_For each non-trivial decision in §1-§4, write one ADR-style block. Single DEC-N block ≤ 30 lines (raw `wc -l` including code fences/tables). Refinement iteration history does not live here — only the final state. Skip entire §5 with "N/A — no material architecture decisions" when feature scope is purely additive without architectural impact._

### [DEC-N] {Decision title}

- **Context**: {why the decision is needed, ≤2 lines}
- **Decision**: {what was chosen, ≤2 lines}
- **Source verification**: {file:line in repo and/or external doc URL, ≤3 lines}
- **Trade-offs**: {alternative vs chosen option, ≤3 lines — required for L2/L3; "N/A (L1 trivial reuse)" allowed for L1}
- **Consequences**: {follow-on constraints or downstream implications, ≤2 lines — required for L2/L3; "N/A (L1)" allowed for L1}

(Repeat per DEC-N.)

## 6. Integration Points

### 6.1 New files
- `{path}` — {purpose, ref DEC-N}

### 6.2 Modified files
| ID | Target | Action | File:line | Evidence | Rationale |
|----|--------|--------|-----------|----------|-----------|
| INT-1 | {path} | modify / reuse / add | {path:line} | {} | {} |

### 6.3 Intentionally unchanged (drift prevention)

_Files in this feature's domain that are intentionally NOT modified. Anchors code-planner against unintended scope creep. Omit this subsection when there are no such files._

- `{path}` — {why this file is in domain but stays unchanged}

## 7. Risks & Mitigations

_Lock-time / architectural risks only. Sequencing / test / rollback risks belong to code-plan §5 Risk Register. Each row ≤ 4 lines (mitigation cell single line ≤ 200 chars)._

| ID | Risk | Likelihood | Impact | Mitigation | Rollback path |
|----|------|-----------|--------|------------|---------------|
| R-1 | {risk} | L/M/H | L/M/H | {} | {} |

## 8. Phase1 Amendments

_4-short-field structure. No prose paragraphs. Cell content single line ≤ 120 chars; no `\n`, no bullet markers._

| # | Section | Change (≤120 chars) | Why (≤120 chars) | Affected DEC | Approved at |
|---|---------|---------------------|------------------|--------------|-------------|

## 9. Open Items

### 9.1 Blocking technical questions (resolve before freeze)
| # | Question | Impact | Proposed Options |
|---|----------|--------|------------------|

### 9.2 Non-blocking
| # | Question | Impact | Proposed Options |
|---|----------|--------|------------------|

### 9.3 Routed to req-clarifier (out-of-scope here)
| # | Item raised | Routed at | Note |
|---|-------------|-----------|------|

### 9.4 Open Items for Phase 2 (code-plan hand-off)

_Items that this spec intentionally defers to code-planner. Distinct from §9.1/§9.2 — these are decided enough to freeze but require code-plan to verify during sequencing._

| # | Item | Owner | Type |
|---|------|-------|------|
| O1 | {item} | code-planner | implementation-time verification |

<!-- audit-only-below — readers (code-planner, code-plan-review-*, code-implementer) MUST stop here -->

## 10. Decision Audit Trail

_Autonomy-tier metadata, keyed by DEC-N. Not part of code-planner's input. Used by the human reviewer at freeze time and by Forced L1 Review._

| DEC | Decided | Round | Source / Rubric note |
|-----|---------|-------|----------------------|
| DEC-1 | Autonomously \| With user (confirmed) \| With user (discussed) | {N} | {short rubric/source citation} |
```
