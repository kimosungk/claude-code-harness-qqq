---
name: interview-nltp
description: "qqq:interview-nltp — Convert a clarified requirement spec into a Gherkin-style Natural-Language Test Procedure, harden the draft through an automatic reviewer gate (qqq:nltp-reviewer) before the user ever sees it, then iterate with the user on free-text feedback (each user revision triggers one auto-review pass) until approved. Input: phase1-spec.md (+ optional phase1-ui-outline.md). Output: phase1-nltp.md plus phase1-nltp-review-{k}.md per round."
argument-hint: "<path to phase1-spec.md> [iterations=N]"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, AskUserQuestion, Bash(dirname *), Bash(basename *), Bash(test *), Bash(date *), Bash(ls *), Bash(find *), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**), Task
model: sonnet
effort: high
---

# Interview NLTP — Reviewer-Hardened Test Procedure

The NLTP is the **downstream completion criteria** for Phase 2 / Phase 3. `code-planner` cites NLTP scenario IDs in its verification path; `code-implementer` treats each `Then` as a manual-verification done/not-done judgment. Therefore the draft must pass an automatic reviewer gate (`qqq:nltp-reviewer`) before the user sees it, and **every user revision triggers another reviewer pass** so the version the user finally approves is always reviewer-hardened.

Optimize for readability and 1:1 traceability to acceptance criteria, not for test-automation execution.

## Hard Rules

- Never modify `phase1-spec.md` or `phase1-ui-outline.md` — frozen inputs
- Never invent ACs / Edge cases not in the spec — *first-line defense; reviewer rarely sees `scope_drift`*
- Never add implementation detail (React/Zustand/API/DB names) — only user-visible behavior
- Never expand or shrink the locked Coverage scope without explicit user instruction
- Never auto-remove a `scope_drift` finding — surface as caveats
- Never show the user a draft before at least one auto-review round has completed
- Never create a new session directory — reuse the parent of `phase1-spec.md`
- Every Scenario must appear in the Traceability table; orphans are not allowed

## Process

### Phase 0: Resolve session dir + iteration budget

1. `dirname "<injected phase1-spec.md path>"` → session dir. If no path, ask the user.
2. Parse `iterations=N` (default `2`) — this caps **only the initial auto-review loop in Phase 4**. Phase 5 user-revision auto-review is one round per revision, not consuming this budget.

### Phase 1: Read & restate

Read `phase1-spec.md` fully. If `phase1-ui-outline.md` exists in the same dir (`test -f`), read it too. Extract spec §1/§2/§3/§4/§6/§8/§9/§10. Restate understanding in ≤10 bullets and confirm with the user.

### Phase 2: Coverage scope (locked)

Use `AskUserQuestion`:
- **A** — All AC + all Edge Cases
- **B** — P0 (Must Have) AC only
- **C** — User-specified subset (collect via plain text)

Record verbatim in the NLTP header. Only the user can change scope after this — never auto-change.

### Phase 3: Initial draft (not shown to user)

Write `<session-dir>/phase1-nltp.md` per the template at the bottom. Do not show it to the user yet.

**Strict scope-drift prevention**: before writing each Scenario, verify it traces to a concrete AC/Edge inside the locked scope. If not, drop it — do not rely on the reviewer.

Conventions:
- One `## Feature:` block per Must-Have feature in scope
- `### Scenario: AC-N - <summary>` for ACs, `### Scenario: EDGE-N - <summary>` for edges
- Lift concrete UI references (button labels, page names) from `phase1-ui-outline.md` when present
- Header records scope, status, iterations, and a `Review:` placeholder (filled in Phase 4)
- Traceability table rows point to spec sections

### Phase 4: Auto-review loop (max `iterations` rounds)

One round:

1. Resolve round `k` from existing `phase1-nltp-review-*.md` (max + 1, default 1)
2. Invoke reviewer:
   ```text
   Task(subagent_type: "qqq:nltp-reviewer",
        description: "Review phase1-nltp.md round {k}",
        prompt: "NLTP: <abs>\nSpec: <abs>\nUI Outline: <abs|none>\nSession dir: <abs>\nRound: {k}\nArtifact: <abs>/phase1-nltp-review-{k}.md\nCoverage scope: <verbatim>")
   ```
3. Read the round artifact. Parse `Verdict` and the `## Issues` block (labels: `coverage_missing`, `traceability_orphan`, `verifiability`, `scope_drift`).
4. **If `OKAY`**: break. Final auto-review verdict = `OKAY`.
5. **If `REJECT`**: apply all issues in a single revision pass per the rule below, then loop.
6. **If `k == iterations` and still `REJECT`**: stop. Final verdict = `Ready with caveats`.

#### Issue handling (one rule)

For each issue in the reviewer's `## Issues` block, apply the **minimum diff** that addresses the Fix line. Two exceptions:

- `scope_drift` — **never modify NLTP**; record as caveat only (it surfaces in Phase 5)
- `verifiability` whose `Fix:` says "no clue in spec or ui-outline" — **append to NLTP `## Open Questions`** (`- [ ] {scenario id} — {vague step}; needs user clarification`); leave the Scenario itself unchanged

`coverage_missing` and `traceability_orphan` are mechanical — apply the Fix line directly. `verifiability` with a cited clue is a wording rewrite using the clue.

#### Header update before exiting Phase 4

Single Write together with the same-round revisions, set the `Review:` line in the NLTP header:

```
> Review: OKAY (auto rounds: K) | Ready with caveats — {N issues: scope_drift={s}, verifiability_open={v}}
```

`K` is the cumulative reviewer-round count seen so far (incremented again in Phase 5 user-revision rounds). Per-round detail lives in the artifact files; do not maintain a separate log.

### Phase 5: User feedback loop (auto-review on every revision)

1. Print the absolute path of `phase1-nltp.md`.
2. Summarize in ≤8 bullets: Feature/Scenario counts, scope recap, ui-outline yes/no, auto-review outcome (rounds + verdict + issue counts), inline caveats up to 5 with `[scope_drift]` or `[verifiability_open]` tags (overflow → "see phase1-nltp-review-{K}.md").
3. Wait for free-text feedback. Do **not** use `AskUserQuestion` here.
4. Classify each piece of feedback: structural / step-level / coverage / caveat-decision / out-of-scope. Reject out-of-scope ("belongs in code-planner / E2E phase") briefly.
5. **When the user requests revision** (anything except plain approval): apply the minimum-diff edits for that revision, then **invoke the reviewer once** with a fresh round number resolved as in Phase 4 step 1 (max of existing `phase1-nltp-review-*.md` + 1). Apply the same auto-fix rule. Update the header `Review:` line (advance `K` to the new total). Re-show summary in step 2 form. Loop.
6. **When the user signals approval** (`ok`, `approve`, `proceed`, `확정`, `다음 단계`, `looks good`): exit to Phase 6.

If the user goes silent, do not assume approval. Exit with the last draft and a note that approval is still required.

### Phase 6: Freeze & hand-off

In a single Write:

1. Header: flip `Status: Draft` → `Status: Approved`. Set `Iterations:` to the user-feedback iteration count N. Preserve the latest `Review:` line.
2. Append at the very end:
   ```
   ---
   Status: Approved by user
   Approved at: {YYYY-MM-DD HH:MM}
   Iterations (user feedback): {N}
   Auto-review rounds total: {K}   (Phase 4: up to {iterations}; Phase 5: one per user revision)
   Final review verdict: {OKAY | Ready with caveats — N issues}
   Next phase input: phase1-spec.md + phase1-nltp.md
   ```
3. Print the file path and:
   ```
   qqq  # select tech-interviewer or code-planner — phase1-nltp.md becomes an input alongside phase1-spec.md
   ```
4. Stop.

## Output File Template

```markdown
# Natural-Language Test Procedure (NLTP) — {Feature Name}

> Created: {YYYY-MM-DD HH:MM}
> Spec: ./phase1-spec.md
> UI Outline: ./phase1-ui-outline.md   <!-- include only when present -->
> Coverage: {All AC+Edge | P0 AC only | User-defined: <list>}
> Status: Draft
> Iterations: 0
> Review: pending   <!-- updated by Phase 4 / Phase 5: "OKAY (auto rounds: K)" or "Ready with caveats — N issues: scope_drift=S, verifiability_open=V" -->

## Feature: {Feature 1 Name}

Background: {one line on the user value verified here}

### Scenario: AC-1 - {short summary}

**Given** ...
**And** ...
**When** ...
**Then** ...
**And** ...

### Scenario: AC-2 - {short summary}

...

## Feature: Error and Edge Cases

### Scenario: EDGE-1 - {empty state / network failure / etc.}

...

## Traceability

| Scenario   | Source        | Spec reference     |
|------------|---------------|--------------------|
| AC-1 ...   | AC-1          | phase1-spec.md §4  |
| EDGE-1 ... | Edge Case #1  | phase1-spec.md §8  |

## Open Questions

- [ ] {item — write "None." if empty. Auto-fix appends `verifiability` items here when no clue is available.}

## Locked Decisions

- {item — "None." if empty}
```
