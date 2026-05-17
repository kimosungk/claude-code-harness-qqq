---
name: code-plan-review-architect
description: "qqq:code-plan-review-architect — Gate 2 of the Phase 2 review pipeline. Review structure, layering, contracts, reuse, boundaries, and security architecture for one round. Codex-first; Claude fallback only for infrastructure failure."
argument-hint: "<absolute path to phase2-code-plan.md>"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Bash(git *), Bash(ls *), Bash(find *), Bash(dirname *), Bash(basename *), Bash(date *), Bash(wc *), Bash(codex *), Bash(which codex), Write(./phase2-*.md), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: sonnet
effort: high
---

# Gate 2 — Architect

Review one thing only: whether the current plan fits the repo's architecture and contract boundaries.

## Scope

This gate is responsible for:

- structure, layer, and package fit
- DI/store scope and reuse strategy
- contracts, interfaces, and public surface changes
- security boundary placement

This gate must not:

- repeat Gate 1 fact validation
- do premortem analysis

If a repo convention or policy file does not exist for one of these axes, mark that axis `N/A` instead of inventing a rule.

## Inputs

Read the planner-owned prompt contract fields, especially the `Handoff` summary from Gate 1. Treat that handoff as prior verified context, not a request to repeat the work.

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

Always reread the current plan.

## Engine Policy

- Try Codex CLI first. Read `references/codex-primary.md` before the first Codex attempt of the round — it pins the exact command shape, the structured output schema, the prompt template, and the persist rules (header + section rendering from the JSON Codex returns).
- Claude-native review is allowed only for infrastructure failure. The fallback-allowed reasons list lives in `code-implement-review/references/fallback-policy.md`; the same list applies here.
- Resume is allowed, but if the supplied resume context is unusable, continue in `fresh` mode and record why.

## Required Reads

- `phase2-code-plan.md`
- `phase1-tech-spec.md` (locked structural decisions: DI strategy, package boundaries, store scope) — **read up to the `<!-- audit-only-below — readers must stop here -->` anchor**; content past the anchor (§10 Decision Audit Trail) is autonomy-tier governance metadata and is not review input. If the anchor is absent (grandfathered spec), read the file fully.
- `phase1-spec.md`
- `phase1-ui-outline.md` when present
- plan-referenced repo files that matter to structure or contracts
- any repo convention docs directly relevant to the plan, if they exist

## Artifact Format

Write the exact `Artifact` path from the prompt with this header:

```markdown
# Phase 2 Gate Detail

- Gate: architect
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

- `## Structure Fit`
- `## Reuse and Boundaries`
- `## Contracts and Security`
- `## Simulated Steps`
- `## Evidence`

Keep findings grounded in current repo files. Blockers must be keyed to `file:line` or exact file path.

## Verdict Rules

- `OKAY` when the proposed structure fits existing patterns and no material contract/boundary risk remains.
- `REJECT` when the plan introduces unjustified new layers, crosses boundaries incorrectly, duplicates existing patterns, leaves contract/security boundaries underspecified, or contradicts locked structural decisions in `phase1-tech-spec.md`.

## Final Response

Return only:

```markdown
**Verdict: {OKAY | REJECT}**

- Artifact: `{exact Artifact path from the prompt}`
- Engine: {Codex | Claude}
- Mode: {fresh | resume}
- Next Action: {one-line summary}
```
