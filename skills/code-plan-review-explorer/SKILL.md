---
name: code-plan-review-explorer
description: "qqq:code-plan-review-explorer — Gate 1 of the Phase 2 review pipeline. Verify plan facts, reuse candidates, impact callers, and known pitfalls for one round. Codex-first; Claude fallback only for infrastructure failure."
argument-hint: "<absolute path to phase2-code-plan.md>"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Bash(git *), Bash(ls *), Bash(find *), Bash(dirname *), Bash(basename *), Bash(date *), Bash(wc *), Bash(codex *), Bash(which codex), Write(./phase2-*.md), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: sonnet
effort: high
---

# Gate 1 — Explorer

Review one thing only: the factual grounding of the current `phase2-code-plan.md`.

## Scope

This gate is responsible for:

- verifying the plan's factual premises against the repo
- checking whether the proposed reuse targets really exist
- mapping impacted callers and touch points
- collecting known pitfalls already visible in the repo

This gate must not:

- make structure/layer/package judgments
- do security architecture design
- run premortem or failure-mode speculation

## Inputs

Read the planner-owned prompt contract fields:

- `Plan`
- `Session dir`
- `Round`
- `Artifact`
- `Mode`
- `Resume session id`
- `Plan fingerprint`
- `Invalidated by`
- `Change summary`
- `Handoff` (normally `none` for this gate)

Always reread the current plan even in resume mode.

## Engine Policy

- Try Codex CLI first. Read `references/codex-primary.md` before the first Codex attempt of the round — it pins the exact command shape, the structured output schema, the prompt template, and the persist rules (header + section rendering from the JSON Codex returns).
- Claude-native review is allowed only when Codex is unavailable or fails for infrastructure reasons such as missing CLI, auth failure, quota/rate-limit, model unavailable, or transport/runtime failure. The fallback-allowed reasons list lives in `code-implement-review/references/fallback-policy.md`; the same list applies here.
- If resume context is missing or unusable, continue the review in `fresh` mode and state that in the artifact.

## Required Reads

- `phase2-code-plan.md`
- `phase1-tech-spec.md` (to verify plan's technology and API references align with locked choices)
- `phase1-spec.md`
- `phase1-ui-outline.md` when present
- `phase1-nltp.md` when present
- every repository file cited by the plan
- any obvious neighboring files needed to validate reuse or caller impact

## Artifact Format

Write the gate detail artifact to the exact `Artifact` path from the prompt with this header:

```markdown
# Phase 2 Gate Detail

- Gate: explorer
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

- `## Premise Check`
- `## Tech Spec Consistency` (verify plan references the libraries, APIs, and integration points specified in `phase1-tech-spec.md` — existence and reference checks only, not strategy fit; when present)
- `## Reuse Candidates`
- `## Impact Caller Map`
- `## Known Pitfalls`
- `## NLTP Coverage` (verify plan's verification path covers NLTP scenarios; when present)
- `## Evidence`

Always populate `## Evidence` with the key `file:line` anchors used to form the verdict. When the plan is blocked, every blocking finding must be keyed to a `file:line` or exact file path.

## Verdict Rules

- `OKAY` when the plan's factual grounding is materially correct.
- `REJECT` when the plan relies on nonexistent files/symbols, misses critical impact surface, proposes reuse that the repo does not support, or references technologies or APIs that contradict the locked choices in `phase1-tech-spec.md`.

## Final Response

Return only:

```markdown
**Verdict: {OKAY | REJECT}**

- Artifact: `{exact Artifact path from the prompt}`
- Engine: {Codex | Claude}
- Mode: {fresh | resume}
- Next Action: {one-line summary}
```
