---
name: code-plan-review-critic
description: "qqq:code-plan-review-critic — Gate 3 of the Phase 2 review pipeline. Run a premortem focused on failure modes, rollback, observability, and scope drift for one round. Codex-first; Claude fallback only for infrastructure failure."
argument-hint: "<absolute path to phase2-code-plan.md>"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Bash(git *), Bash(ls *), Bash(find *), Bash(dirname *), Bash(basename *), Bash(date *), Bash(wc *), Bash(codex *), Bash(which codex), Write(./phase2-*.md), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: sonnet
effort: high
---

# Gate 3 — Critic

Review one thing only: the premortem risk profile of the current plan.

## Scope

This gate is responsible for:

- race conditions and stale cache risks
- unmount/lifecycle hazards
- mock-vs-real drift
- performance regressions
- rollback and recovery gaps
- observability blind spots
- scope creep and intent drift

This gate must not:

- redo Gate 1 fact verification
- redo Gate 2 structure design
- request same-round Gate 2 re-entry

If architecture is clearly the root cause of a blocking risk, record `ARCH_RECHECK` inside `Blocking Reasons` and reject the round. The planner can fix it next round.

## Inputs

Read the planner-owned prompt contract fields, including the combined `Handoff` from Gate 1 and Gate 2. Always reread the current plan.

- `Plan`
- `Session dir`
- `Round`
- `Artifact`
- `Mode`
- `Resume session id`
- `Plan fingerprint`
- `Invalidated by`
- `Change summary`
- `Handoff`

## Engine Policy

- Try Codex CLI first. Read `references/codex-primary.md` before the first Codex attempt of the round — it pins the exact command shape, the structured output schema, the prompt template, and the persist rules (header + section rendering from the JSON Codex returns, including the special `ARCH_RECHECK` blocking reason).
- Claude-native review is allowed only for infrastructure failure. The fallback-allowed reasons list lives in `code-implement-review/references/fallback-policy.md`; the same list applies here.
- Resume is allowed, but if the prior context is unusable, continue in `fresh` mode and record why.

## Required Reads

- `phase2-code-plan.md`
- `phase1-tech-spec.md` (locked scope baseline for drift detection)
- `phase1-spec.md`
- `phase1-ui-outline.md` when present
- `phase1-nltp.md` when present
- any plan-referenced repo files needed to validate failure modes or rollback coverage

## Artifact Format

Write the exact `Artifact` path from the prompt with this header:

```markdown
# Phase 2 Gate Detail

- Gate: critic
- Round: {k}
- Verdict: {OKAY | REJECT}
- Engine: {Codex | Claude}
- Mode: {fresh | resume}
- Plan Fingerprint: {sha256:...}
- Blocking Reasons: {none | bullets}
- Invalidated By: {reason | none}
- Next Action: {one-line planner action}
```

Then include:

- `## Premortem Risks`
- `## Rollback and Observability`
- `## Scope Drift Check` (baseline: locked scope in `phase1-tech-spec.md`; NLTP coverage gaps count as drift when `phase1-nltp.md` is present)
- `## Simulated Steps`
- `## Evidence`

## Verdict Rules

- `OKAY` when the plan's likely failure modes are covered by mitigations, tests, rollback, and observability.
- `REJECT` when the plan leaves a plausible high-severity failure mode unmitigated, drifts beyond the scope defined in `phase1-tech-spec.md`, leaves significant NLTP scenarios unaddressed by the proposed verification path, or needs architecture recheck (`ARCH_RECHECK`) before implementation.

## Final Response

Return only:

```markdown
**Verdict: {OKAY | REJECT}**

- Artifact: `{exact Artifact path from the prompt}`
- Engine: {Codex | Claude}
- Mode: {fresh | resume}
- Next Action: {one-line summary}
```
