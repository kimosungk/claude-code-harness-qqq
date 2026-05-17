---
name: code-plan
description: "qqq:code-plan — Produce an implementation plan from an approved spec + tech spec + optional UI outline / NLTP, hardened by a planner-owned explorer -> architect -> critic review loop. Input: phase1-spec.md + phase1-tech-spec.md (+ phase1-ui-outline.md / phase1-nltp.md when present). Output: phase2-code-plan.md plus canonical Phase 2 review artifacts in the same session directory."
argument-hint: "<path to phase1-spec.md or session dir> [iterations=N]"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, AskUserQuestion, WebSearch, WebFetch, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__query-docs, Bash(dirname *), Bash(basename *), Bash(date *), Bash(git status *), Bash(git diff *), Bash(git log *), Bash(ls *), Bash(find *), Bash(wc *), Bash(shasum *), Bash(sha256sum *), Bash(head *), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**), Task
model: opus
effort: high
---

# Code Plan — Reviewed, Iteration-Hardened Implementation Plan

Turn an approved spec + tech spec + optional UI outline / NLTP into an actionable implementation plan that can be handed to an executor. Drive quality by directly coordinating `qqq:code-plan-review-explorer`, `qqq:code-plan-review-architect`, and `qqq:code-plan-review-critic` through the Task tool in a bounded review loop.

## Hard Rules

- Never invent codebase facts — every claim cites `file:line`
- Never write production code files in this phase
- Always run the planner-owned explorer -> architect -> critic review loop at least once before declaring the plan final
- Never overwrite prior review history silently; append `phase2-review-log.md` per round and preserve compatible `phase2-review-state.json` fields
- Never write the plan outside the session directory derived from the injected input

## Process

### Phase 0: Resolve Session Directory and Inputs

1. Parse arguments. Expected forms:
   - A path to `phase1-spec.md` (session dir = parent)
   - A path to the session directory itself
   - An `iterations=N` token (integer, >=1). Default **3** when absent.
2. Required inputs in the session directory:
   - `phase1-spec.md` (must exist — if missing, stop and ask the user for it)
   - `phase1-tech-spec.md` (required — if missing, stop and instruct the user to run `tech-interviewer` first)
   - `phase1-ui-outline.md` (optional; read when present)
   - `phase1-nltp.md` (optional; read when present)
3. Confirm the resolved session directory + iteration budget with the user.

### Phase 1: Ground in Repository Evidence

1. Read the four primary inputs only:
   - `phase1-spec.md` — full read
   - `phase1-tech-spec.md` — **read up to the `<!-- audit-only-below — readers must stop here -->` anchor line**; do not read past it. Content past the anchor (§10 Decision Audit Trail) is autonomy-tier governance metadata and is not plan input. If the anchor is absent (e.g., grandfathered spec written before the anchor convention), read the file fully — the anchor's absence indicates pre-rule format.
   - `phase1-ui-outline.md` — full read when present
   - `phase1-nltp.md` — full read when present
   - **Do not read** sidecar artifacts in the session dir: `phase1-tech-spec-scope-lint.md`, `phase1-tech-spec-sanity*.md`, `phase1-tech-spec-sanity-output.json`, `phase1-tech-spec-history.md` (if present). These are tech-interviewer process artifacts, not plan input.
2. Map the spec's must-have features to concrete codebase targets using Glob/Grep/Read:
   - Existing modules the change will extend
   - Patterns to mirror (naming, file layout, test style)
   - Likely insertion points for new files
3. Record findings in a working scratch list — this is raw material for the plan, not the plan itself.
4. Treat upstream inputs with distinct roles:
   - `phase1-spec.md`: product scope and non-goals
   - `phase1-tech-spec.md`: locked implementation decisions that must not be re-decided
   - `phase1-ui-outline.md`: UI structure / labels when relevant
   - `phase1-nltp.md`: manual verification coverage and scenario traceability when present

If a project knowledge base directory exists (e.g., `docs/`, `wiki/`), read the top relevant entries. Do not invent context that is not in the repo.

### Phase 2: Draft the Plan

Write `phase2-code-plan.md` using the template below. Key quality bars:

- **Right-sized step count**: the number of steps matches scope, not a default.
- **Testable acceptance per step**: each step names the verifying command/file.
- **Consistent directory structure**: new files slot into the existing tree.
- **Explicit non-goals**: repeat the spec's out-of-scope items so the executor does not drift.
- **Risk register**: list the main risks with mitigation.
- **Traceable verification**: when `phase1-nltp.md` exists, the verification path should reference the covered scenarios instead of inventing a separate manual-test shape.

Before entering the review loop, initialize `phase2-review-log.md` with its title block if it does not exist yet. The planner owns all Phase 2 review artifacts and must preserve prior round history when appending.

The canonical Phase 2 review artifacts for this session are:

- `phase2-review-log.md`
- `phase2-review-state.json`
- `phase2-review-round-{k}.md`
- `phase2-g1-explorer-{k}.md`
- `phase2-g2-architect-{k}.md`
- `phase2-g3-critic-{k}.md`

### Phase 3: Planner-Owned Review Loop

Loop up to `iterations` times. One round:

1. Build a concise `change_summary` — one line per changed area.
   - Round 1: `initial draft`
   - Later rounds: only the concrete planner fixes since the previous round
2. Set `resume_hint`.
   - Round 1: `none`
   - Later rounds: a brief planner guess such as `likely resume explorer + architect; critic fresh`
3. Resolve round `k` from existing `phase2-review-round-*.md`; next round is max + 1, default `1`.
4. Compute a stable plan fingerprint from the current `phase2-code-plan.md`. Prefer `shasum -a 256`; fall back to `sha256sum`. Store it as `sha256:<digest>`.
5. Read any prior `phase2-review-state.json` and keep this compatible sidecar shape:
   ```text
   {
     "current_round": 2,
     "plan_path": "/abs/.../phase2-code-plan.md",
     "last_change_summary": "line1\nline2",
     "last_resume_hint": "text",
     "final_verdict": "",
     "review_loop_completed": false,
     "completed_at": "",
     "gates": {
       "explorer": {
         "last_session_id": "string-or-empty",
         "last_artifact_path": "./phase2-g1-explorer-2.md",
         "last_input_fingerprint": "sha256:...",
         "last_verdict": "OKAY",
         "invalidation_reason": "new touch surface",
         "last_engine": "Codex",
         "last_mode": "fresh"
       },
       "architect": {
         "last_session_id": "string-or-empty",
         "last_artifact_path": "./phase2-g2-architect-2.md",
         "last_input_fingerprint": "sha256:...",
         "last_verdict": "OKAY",
         "invalidation_reason": "",
         "last_engine": "Codex",
         "last_mode": "resume"
       },
       "critic": {
         "last_session_id": "string-or-empty",
         "last_artifact_path": "./phase2-g3-critic-2.md",
         "last_input_fingerprint": "sha256:...",
         "last_verdict": "REJECT",
         "invalidation_reason": "mitigation strategy changed",
         "last_engine": "Claude",
         "last_mode": "fresh"
       }
     }
   }
   ```
   Use the same fields for all three gates. `last_artifact_path` stays session-relative for portability.
6. Decide each gate's mode:
   - Gate 1 `fresh` when the plan introduces new files, symbols, packages, APIs, reference paths, or a wider touch surface. Otherwise `resume`.
   - Gate 2 `fresh` when layering, package boundaries, store scope, reuse strategy, contracts, or security boundaries changed materially. Otherwise `resume`.
   - Gate 3 `fresh` when Gate 1 or Gate 2 is `fresh`, or when mitigation, verification, observability, or rollback strategy changed materially. Otherwise `resume`.
   - `resume_hint` is advisory only. Record it, but make your own decision.
   - Resume is allowed only if the prior gate has a non-empty `last_session_id`, a prior fingerprint, and no current invalidation reason.
   - If a resume attempt fails, rerun that gate as `fresh`, then record the fallback reason in both `phase2-review-state.json` and `phase2-review-log.md`.
7. Build gate artifacts and prompts. The canonical artifact paths for round `k` are:
   - Gate 1: `phase2-g1-explorer-{k}.md`
   - Gate 2: `phase2-g2-architect-{k}.md`
   - Gate 3: `phase2-g3-critic-{k}.md`
   Pass the exact field names below to each gate through `Task`:
   ```text
   Plan: <absolute phase2-code-plan.md path>
   Session dir: <absolute session dir>
   Round: <k>
   Artifact: <absolute artifact path for this gate>
   Mode: <fresh|resume>
   Resume session id: <string-or-empty>
   Plan fingerprint: <sha256:...>
   Invalidated by: <reason or none>
   Change summary:
   <planner summary or "initial draft">
   Handoff:
   <structured notes from earlier gates, or "none">
   ```
   Handoff rules:
   - Gate 1 gets `none`
   - Gate 2 gets a compact explorer summary
   - Gate 3 gets a compact explorer + architect summary
   Never persist a separate handoff file.
8. Invoke the gates sequentially through `Task` in fixed order:
   ```text
   Task(subagent_type: "qqq:code-plan-review-explorer", description: "Review code plan round {k} gate 1", prompt: "<contract above>")
   Task(subagent_type: "qqq:code-plan-review-architect", description: "Review code plan round {k} gate 2", prompt: "<contract above>")
   Task(subagent_type: "qqq:code-plan-review-critic", description: "Review code plan round {k} gate 3", prompt: "<contract above>")
   ```
   Capture the real Task/subagent session id on each run and persist it as `last_session_id`.
9. Apply the early-stop rules exactly:
   - If Gate 1 returns `REJECT`, write Gate 2 and Gate 3 skip stubs with `Verdict: REJECT` and explain the upstream block in `Blocking Reasons`, then stop the round.
   - If Gate 2 returns `REJECT`, write the Gate 3 skip stub with `Verdict: REJECT` and explain the upstream block in `Blocking Reasons`, then stop the round.
   - Skip stubs must preserve the normal gate detail artifact shape.
   - If all three gates return `OKAY`, the round verdict is `OKAY`; otherwise `REJECT`.
10. Write `phase2-review-round-{k}.md` with this structure:
   ```markdown
   # Phase 2 Review Round {k}

   - Round Verdict: {OKAY | REJECT}
   - Gate 1 Verdict: {OKAY | REJECT}
   - Gate 2 Verdict: {OKAY | REJECT}
   - Gate 3 Verdict: {OKAY | REJECT}
   - Gate Engines: G1={Codex|Claude}; G2={Codex|Claude}; G3={Codex|Claude}
   - Gate Modes: G1={fresh|resume}; G2={fresh|resume}; G3={fresh|resume}
   - Escalated Risk: {none | short summary}
   - Planner Action: {highest-priority next action}
   ```
   Then include:
   - `## Gate Summary`
   - `## Simulated Steps`
   - `## Gate Findings`
11. Append one block per round to `phase2-review-log.md`:
   ```markdown
   ## Round {k} — {YYYY-MM-DD HH:MM}
   Round verdict: {OKAY | REJECT}
   Gate verdicts: G1={OKAY | REJECT}; G2={OKAY | REJECT}; G3={OKAY | REJECT}
   Gate artifacts:
   - G1: ./phase2-g1-explorer-{k}.md
   - G2: ./phase2-g2-architect-{k}.md
   - G3: ./phase2-g3-critic-{k}.md
   Gate engines: G1={Codex|Claude}; G2={Codex|Claude}; G3={Codex|Claude}
   Gate modes: G1={fresh|resume}; G2={fresh|resume}; G3={fresh|resume}
   Skipped gates:
   - {none | gate and reason}
   Planner action:
   - {highest-priority fix}
   Unresolved carried forward:
   - {none | issue}
   ```
12. Persist `phase2-review-state.json` after the round with compatible values for:
   - `last_session_id`
   - `last_artifact_path`
   - `last_input_fingerprint`
   - `last_verdict`
   - `invalidation_reason`
   - `last_engine`
   - `last_mode`
   Keep `final_verdict`, `review_loop_completed`, and `completed_at` present when already set; intermediate rounds must leave `review_loop_completed` false.
13. Before treating the round as a substantive review result, check for infrastructure-only failure. Examples:
   - the planner or a gate could not access `Task`
   - the round artifact or review log says there was zero substantive review signal
   - no real gate artifact was produced beyond skip / infrastructure stubs
   In that case, stop immediately, tell the user the review pipeline is blocked by infrastructure, and do **not** spend the remaining review budget pretending it was substantive review.
14. If the round verdict is `REJECT`, revise `phase2-code-plan.md` to address the logged planner actions. Keep the diff minimal.
15. If the round verdict is `OKAY`, stop the loop.
16. If round `k == iterations` and the latest round verdict is still `REJECT`, do **not** silently fall through to handoff. Use `AskUserQuestion` to ask the user whether to:
    - **proceed as `Ready with caveats`** — accept the unresolved issues and let `phase2-code-plan.md` be handed to implementation as-is
    - **run one more review round** — extend the budget by one round and re-enter the loop at step 1 with `k = k + 1`
    - **stop** — leave the loop incomplete and surface the blockers without marking `review_loop_completed: true`

    Only after the user answers, set the plan status accordingly. If the user picked `Ready with caveats`, list the unresolved issues prominently in section 7. If the user picked stop, leave `review_loop_completed: false` in `phase2-review-state.json`.

Do not parallelize review rounds. Each round must read the revised plan.

### Phase 4: Final Handoff

1. Tell the user:
   - Session directory and the output files
   - Canonical review artifacts: `phase2-review-log.md`, `phase2-review-state.json`, `phase2-review-round-{k}.md`, and the three gate detail files for the latest round
   - Final reviewer verdict (`OKAY` or `Ready with caveats`)
   - Rounds used out of the budget
2. Before stopping, update `phase2-review-state.json` so it marks the review loop complete for the current plan:
   - `final_verdict`: `{OKAY | Ready with caveats}`
   - `review_loop_completed`: `true`
   - `completed_at`: `{YYYY-MM-DD HH:MM}`
   - preserve the latest gate `last_input_fingerprint` values so they still match the reviewed plan
3. State that `phase2-code-plan.md` is the next-phase input for implementation.
4. Print the next-step command:
   ```text
   qqq:code-implementer
   ```
5. Stop. Do not start implementation yourself.

## phase2-code-plan.md Template

```markdown
# Implementation Plan — {Feature Title}

> Created: {YYYY-MM-DD HH:MM}
> Spec: ./phase1-spec.md
> Tech Spec: ./phase1-tech-spec.md
> UI Outline: ./phase1-ui-outline.md (or "N/A — non-UI feature")
> NLTP: ./phase1-nltp.md (or "N/A — no NLTP provided")
> Reviewer: qqq:code-planner
> Status: Draft | Ready with caveats | Approved by user

## 0. Summary

- Feature: {1-line}
- Scope size: {LOW | MEDIUM | HIGH}
- Est. files touched: {count}
- Est. lines changed: {order-of-magnitude}

## 1. Grounding Evidence

Key files this plan depends on (verified via repo inspection):

| File | Line | Why it matters |
|------|------|---------------|
| {path} | {N} | {one-line} |

## 2. Directory and File Layout

New files:
- `{path}` — {purpose}

Modified files:
- `{path}` — {what changes}

Rationale for any new directory (if applicable):
- {reason the existing tree was insufficient}

## 3. Implementation Steps

> Step count is right-sized to scope — not fixed to any default.

### Step 1 — {title}
- **Change**: {concrete change with file:line or path}
- **Why**: {link back to spec section, tech-spec section, and UI/NLTP reference when relevant}
- **Acceptance**: {command or artifact that proves this step is done}
- **Depends on**: {none | Step k}

### Step 2 — ...

## 4. Non-Goals

Repeated from the spec so the executor cannot drift:
- {non-goal}

## 5. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|-----------|
| 1 | {risk} | L/M/H | L/M/H | {mitigation} |

## 6. Verification Path

- Unit: {command / files}
- Integration: {command / files}
- Manual: {what the human should see and do; reference NLTP scenario IDs when present}

## 7. Unresolved After Review (if Ready with caveats)

- [severity] {issue} — why it remains unresolved / proposed path forward
```

## phase2-review-log.md Template

```markdown
# Phase 2 Review Log

> Reviewer: qqq:code-planner
> Iteration budget: {N}

## Round 1 — {YYYY-MM-DD HH:MM}
Round verdict: {OKAY | REJECT}
Gate verdicts: G1={OKAY | REJECT}; G2={OKAY | REJECT}; G3={OKAY | REJECT}
Gate artifacts:
- G1: ./phase2-g1-explorer-1.md
- G2: ./phase2-g2-architect-1.md
- G3: ./phase2-g3-critic-1.md
Gate engines: G1={Codex|Claude}; G2={Codex|Claude}; G3={Codex|Claude}
Gate modes: G1={fresh|resume}; G2={fresh|resume}; G3={fresh|resume}
Skipped gates:
- {none | gate and reason}
Planner action:
- {highest-priority fix}
Unresolved carried forward:
- {none | issue}
```
