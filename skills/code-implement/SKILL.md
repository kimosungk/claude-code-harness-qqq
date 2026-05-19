---
name: code-implement
description: "qqq:code-implement — Execute an implementation plan and harden the diff through iterative review via qqq:code-implement-reviewer (Codex-first, Claude fallback on infrastructure failure). Primary input: phase2-code-plan.md. Optional read-only references: phase1-tech-spec.md and phase1-nltp.md when present. Output: phase3-implement-log.md in the same session directory + the actual code changes in the repo."
argument-hint: "<path to phase2-code-plan.md or session dir> [iterations=N]"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Write, Edit, Bash, Task, AskUserQuestion
model: opus
effort: high
---

# Code Implement — Execute the Plan, Review via Codex-First Reviewer

The loop is: execute plan → verify locally → invoke Codex-backed reviewer → revise → repeat up to `iterations` rounds. Only declare done when the reviewer returns OKAY or the budget is spent.

## Hard Rules

- **Phase 3 may only proceed if `phase2-review-state.json` exists and has `review_loop_completed: true`** (D1− gate — fail closed)
- Plan (`phase2-code-plan.md`) is read-only input
- Plan is the sole source of truth for scope and sequencing
- `phase1-tech-spec.md` and `phase1-nltp.md` are read-only reference inputs only; they may clarify ambiguity or verification intent, but must never override the plan or widen scope
- Every implementation step must end with a concrete verification command and its fresh output
- Always invoke `qqq:code-implement-reviewer` at least once before declaring the task complete
- Never parallelize reviewer rounds; sequential only
- Never commit without explicit user instruction; the harness stops at a clean working diff + review log

## Process

### Phase 0: Resolve Session Directory and Inputs

1. Parse arguments. Expected forms:
   - A path to `phase2-code-plan.md` (session dir = parent)
   - A path to the session directory itself
   - An `iterations=N` token (integer, ≥1). Default **3**.
2. Required inputs in the session directory (the qqq dispatcher pre-attaches present files as `@`-mentions in your first user turn — use those attachments directly, do not re-Read):
   - `phase2-code-plan.md`
   - `phase2-review-state.json` with `review_loop_completed: true` — **D1− prerequisite gate**. The file arrives attached; parse the attached JSON. If the attachment is missing (file absent on disk), unreadable, or the flag is anything other than the boolean `true`, output exactly the line `prerequisite invalid: phase2 review loop not completed` and stop. Do not proceed to use the plan.
   - **D1− advisory — plan-fingerprint drift check (warn-only, never blocking)**. After the prerequisite gate above passes:
     1. Compute `current_plan_fp = "sha256:" + sha256(<phase2-code-plan.md>)` (prefer `shasum -a 256`, fall back to `sha256sum`). Run the hash on the file path — do not Read the file to feed it through a hash, the attached content is your source of truth for the plan body but `shasum` of the file path is the canonical fingerprint.
     2. Use `reviewed_fp = .gates.critic.last_input_fingerprint` from the attached `phase2-review-state.json`.
     3. If `reviewed_fp` is missing, empty, or not a string, **skip the comparison silently** — fingerprint tracking is advisory and must not regress legacy state files.
     4. If both fingerprints are present and they differ, print exactly one line:
        `[warn] plan fingerprint drift since review — current=<current_plan_fp> reviewed=<reviewed_fp>; implementing without re-review (D1−)`
        Then proceed with implementation. Do **not** stop. D1−'s "no validation" stance is preserved (the run is not blocked); the warning exists so plan drift surfaces here instead of in a confused PR review.
   - `phase1-tech-spec.md` and `phase1-nltp.md` are optional siblings; when they exist on disk they arrive pre-attached and may be consulted as read-only references after the plan content is internalized
3. Confirm the resolved session directory + iteration budget with the user.

### Phase 1: Execute the Plan

1. Use the attached `phase2-code-plan.md` content directly (do not call `Read` on it again). Internalize:
   - Steps and their order / dependencies
   - Directory/file layout contract
   - Non-goals
   - Verification path
2. If `phase1-tech-spec.md` and/or `phase1-nltp.md` arrived in your attachments, use that content to support two narrow purposes:
   - resolve ambiguity without re-planning
   - confirm that implementation verification still matches the intended behavior
   If they conflict with the plan, stop and surface the mismatch to the user instead of silently choosing one. No attachment ⇒ the file does not exist; proceed without it.
3. For each step, in order:
   - Read the target files first (do not blind-edit)
   - Make the minimal correct change that satisfies the step's acceptance
   - Run the step's acceptance command immediately after
   - If the command fails, fix before moving on — do not accumulate broken steps
4. After all steps, run the plan's aggregate verification path (unit / integration / build / typecheck as listed).

### Phase 2: Implementation Log (First Pass)

Write `phase3-implement-log.md` (overwrite any prior content — the review log is separate):

```markdown
# Implementation Log — {Feature Title}

> Created: {YYYY-MM-DD HH:MM}
> Plan: ./phase2-code-plan.md
> Tech Spec Reference: ./phase1-tech-spec.md (or "N/A — not consulted")
> NLTP Reference: ./phase1-nltp.md (or "N/A — not consulted")
> Reviewer: qqq:code-implement-reviewer
> Status: Draft

## Diff Summary (post-implementation, pre-review)

| File | Change | Lines Changed |
|------|--------|---------------|
| {path} | {created / modified / deleted} | {+N / -M} |

## Per-Step Outcomes

### Step 1 — {title}
- Files: {list}
- Acceptance command: `{cmd}`
- Output: `{first/last lines of output}` → Pass / Fail

## Aggregate Verification

- `{cmd}` → {result}

## Known Open Concerns Before Review

- {concern}
```

### Phase 3: Reviewer Loop

Loop up to `iterations` rounds. One round:

1. **Invoke reviewer** via Task using the labeled input contract defined in `qqq:code-implement-review` (mirror of the Phase 2 planner-side contract):
   ```text
   Plan: <absolute path to phase2-code-plan.md>
   Session dir: <absolute session dir>
   Round: <k>
   Codex artifact: <session_dir>/phase3-codex-review-<k>.md
   Claude fallback artifact: <session_dir>/phase3-claude-review-<k>.md
   Review policy: codex-first
   Plan fingerprint: sha256:<digest>      # optional but recommended; compute via shasum -a 256 or sha256sum
   Implementation log: <session_dir>/phase3-implement-log.md
   ```
   Compose the prompt body from the labels above (one label per line) plus a one-line directive:
   ```
   Run the Codex-first reviewer flow; Claude fallback is allowed only on infrastructure failure. Return verdict OKAY or REJECT with concrete issues keyed to file:line.
   ```
   Then call:
   ```
   Task(
     subagent_type: "qqq:code-implement-reviewer",
     description: "Review implementation round {k}",
     prompt: "<labeled body + directive>"
   )
   ```
   Two artifact labels (one per engine) are required because the persisted filename depends on which engine ran. The reviewer agent owns invoking the review engine and writing the artifact at the labeled path.

2. **Read the reviewer's verdict** — `OKAY` or `REJECT` plus issue list with severity + fix suggestions.

3. **Append the round to `phase3-implement-log.md`**:
   ```
   ## Review Round {k} — {YYYY-MM-DD HH:MM}
   Verdict: {OKAY | REJECT}
   Review artifact: ./phase3-{codex|claude}-review-{k}.md
   Reviewer engine: {Codex | Claude}
   Issues addressed in this round (next step):
   - [severity] file:line — issue → planned fix
   Deferred:
   - [severity] … → reason
   ```

4. **Revise the code** to address the reviewer's issues. Keep the diff minimal — touch only what the reviewer flagged or directly depends on it. Re-run the affected verification commands.

5. If verdict is `OKAY`, break.

6. If round `k == iterations` and verdict is still `REJECT`, do **not** silently set caveats and exit. Use `AskUserQuestion` to ask the user whether to:
    - **finalize as `Complete with caveats — {N} unresolved`** — accept the remaining issues and close the implementation phase
    - **run one more review round** — extend by one round and re-enter the loop at step 1 with `k = k + 1`
    - **stop** — leave the implementation incomplete and surface the unresolved issues without finalizing

    Apply the user's choice. If the user picked stop, do not append a final-status line; simply summarize the unresolved issues and the current diff state.

Do not parallelize reviewer calls. Each round re-reads the current working tree.

### Phase 4: Final Report

1. Append the closing section to `phase3-implement-log.md`:
   ```
   ---
   Status: Complete | Complete with caveats — {N} unresolved
   Final reviewer verdict: {OKAY | Complete with caveats}
   Rounds used: {k} / {iterations}
   Completed at: {YYYY-MM-DD HH:MM}
   ```
2. Tell the user:
   - Session directory
   - The files changed (path + line counts)
   - Final verification evidence (command → result)
   - Reviewer verdict and any unresolved issues

## Failure Recovery

When blocked during implementation:
1. Try a different approach (same step, different tactic).
2. Break the step into smaller sub-steps and verify incrementally.
3. Re-check assumptions against repo evidence via Read/Grep.
4. Reuse existing patterns before inventing new ones.

After multiple failed approaches on the same blocker, stop adding risk, document the blocker in the log's "Known Open Concerns" section, and surface it to the user with a clear next-step proposal (revert, re-plan, or defer).

## Final Checklist

- Did I follow every step of the plan?
- Did I collect fresh verification output (not cached)?
- Did I invoke `qqq:code-implement-reviewer` at least once?
- Is `phase3-implement-log.md` up to date with per-step outcomes and every review round?
- Did I keep scope tight and avoid drive-by refactors?
- Did I skip the commit unless the user explicitly asked?
