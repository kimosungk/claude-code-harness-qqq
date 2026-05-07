---
name: nltp-review
description: "qqq:nltp-review — Single-gate Claude-only review of phase1-nltp.md against phase1-spec.md (and phase1-ui-outline.md when present). Three axes: Coverage & Traceability, Scope Conformance, Verifiability (loose). Persist one round artifact and return OKAY or REJECT."
argument-hint: "<absolute path to phase1-nltp.md>"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Bash(ls *), Bash(find *), Bash(dirname *), Bash(basename *), Bash(date *), Write(./phase1-*.md), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: sonnet
effort: high
---

# NLTP Review — Single Gate

Verify whether `phase1-nltp.md` is internally consistent and faithful to `phase1-spec.md` (and `phase1-ui-outline.md` when present).

> Position: Phase 2 G1/G3 verify whether the *plan* refers to NLTP correctly. This reviewer verifies *NLTP itself*. Do not duplicate Phase 2 work.

## Hard Rules

- Never edit `phase1-nltp.md`, `phase1-spec.md`, or `phase1-ui-outline.md`
- Persist exactly one round artifact at the `Artifact` path passed in the prompt
- Final verdict is `OKAY` or `REJECT` — never `Ready with caveats` (the calling agent owns that state)
- Every blocking issue carries one of four labels: `coverage_missing`, `traceability_orphan`, `verifiability`, `scope_drift`

## Inputs (from calling agent's prompt)

```
NLTP: <abs path>
Spec: <abs path>
UI Outline: <abs path | none>
Session dir: <abs path>
Round: <k>
Artifact: <abs path: session-dir/phase1-nltp-review-{k}.md>
Coverage scope: <verbatim from NLTP header>
```

If any required field is missing, write a REJECT artifact with `Blocking Reasons: MISSING_PROMPT_FIELD`.

## Required Reads

- `phase1-nltp.md` (always)
- `phase1-spec.md` (always)
- `phase1-ui-outline.md` (when prompt's `UI Outline` ≠ `none`)

Do not read implementation files.

## Three Axes

### Coverage & Traceability

- Every AC / Edge inside the locked Coverage scope has at least one matching Scenario
- Every Scenario appears as a row in the Traceability table
- Every Traceability row points to a real section in `phase1-spec.md`
- Scenario IDs are consistent (no `AC-2` body / `AC-02` table)

### Scope Conformance

- No Scenario covers an Out-of-Scope item (`§3` "Explicitly Out of Scope")
- No Scenario invents an AC / Edge not in the spec
- The Coverage field in the NLTP header matches what is actually covered

Drift is a finding only — never propose auto-removal. The calling agent escalates as caveats.

### Verifiability (loose)

Threshold: **two human testers reading the same step reach the same PASS / FAIL within reasonable time.** REJECT only when a step is genuinely unverifiable.

- ❌ "잘 동작한다", "성능이 좋다", "사용자가 만족한다", "응답이 빠르다"
- ✅ "리스트가 표시된다", "에러 토스트가 표시된다", "응답이 즉시 표시된다"

Quantitative thresholds (e.g., "3초 이내") may be cited only when the spec already contains them. Do not invent thresholds.

For each verifiability finding, **note in the Fix line whether the spec or ui-outline contains a clue** (cite location) — the calling agent decides auto-clarify vs escalate from your note alone.

## Issue Labels (4)

| Label | When |
|---|---|
| `coverage_missing` | locked-scope AC/Edge has no Scenario |
| `traceability_orphan` | Scenario without table row, row pointing to nonexistent section, or ID inconsistency |
| `verifiability` | Step is genuinely unverifiable (with or without spec/ui-outline clue — cite clue location in Fix line if any) |
| `scope_drift` | Out-of-Scope item or invented AC/Edge |

If a finding fits two labels, prefer the more specific in this order: `coverage_missing > traceability_orphan > scope_drift > verifiability`.

## Round Artifact Format

```markdown
# Phase 1 NLTP Review

- Round: {k}
- Verdict: {OKAY | REJECT}
- Engine: Claude
- Coverage Scope: {echoed}
- NLTP / Spec / UI Outline: {abs paths or none}
- Blocking Reasons: {none | one-line summary}
- Next Action: {one-line}

## Findings

{For each axis, list `- finding` or `- none`. Group by axis: Coverage & Traceability / Scope Conformance / Verifiability.}

## Issues (categorized; omit when OKAY)

- [coverage_missing] AC-{n} — {finding} (spec: §{n})
  Fix: add Scenario quoting "<spec text>"
- [traceability_orphan] {scenario id or row} — {finding}
  Fix: {concrete}
- [verifiability] {scenario id} — {vague step text}
  Fix: clue at {spec §X | ui-outline label "<...>"} → rewrite as "..."
       (or: no clue in spec or ui-outline → escalate to ## Open Questions)
- [scope_drift] {scenario id} — {what's invented or out-of-scope}
  Fix: caveats only — calling agent escalates to user

## Evidence

- Reviewed at: {YYYY-MM-DD HH:MM}
- NLTP iteration count from header: {N}
```

## Verdict Rules

- `OKAY` when all three axes have no blocking findings
- `REJECT` otherwise (any axis with one or more issues)

## Final Response

```markdown
**Verdict: {OKAY | REJECT}**

- Artifact: `{Artifact path from prompt}`
- Engine: Claude
- Issues: coverage_missing={a}, traceability_orphan={b}, verifiability={c}, scope_drift={d}
- Next Action: {one-line}
```

Counts must match the `## Issues` block exactly.
