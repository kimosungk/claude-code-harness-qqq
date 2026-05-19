# Amendment Gate — Examples, Edge Cases, Failure Recovery

Companion to the atomic skeleton in `SKILL.md` Phase 4. The skeleton is the only safe path to edit `phase1-spec.md`; this file documents the situations where it gets tricky.

## When the Gate Fires

The Gate fires only when an in-progress tech decision **requires** a change to `phase1-spec.md`. Specifically:

1. The spec contradicts itself in a way that blocks a tech choice (e.g., §3 says "must support 10k concurrent users" but §4 acceptance test says "tested with 1 user").
2. A tech choice you want to make would violate a frozen UX constraint, and the user-facing tradeoff is real (e.g., spec says "results render instantly" but the only viable backend is paginated → spec must amend to "first page renders within 1s, subsequent pages on demand").
3. A material gap is exposed by tech-side scrutiny (e.g., spec says "alarms persist" but doesn't say across devices vs across sessions; tech can't pick storage tier without knowing).

The Gate does **not** fire for:
- Wording polish — leave the spec alone if the tech decision works either way.
- "I think this could be clearer" — clarity belongs to req-clarifier on a re-run, not this gate.
- A new feature surfaced mid-interview — stop and route to `req-clarifier`.

## Atomic Sequence — Reminder

The skeleton in SKILL.md is the canonical version. This is a worked walkthrough.

```
1. Quote before/after precisely (one diff per prompt).
2. AskUserQuestion: Approve / Reject / Defer.
3. If Approve:
   a. Edit phase1-spec.md
   b. Re-read; confirm "After" text now present
   c. If phase1-tech-spec.md does not yet exist (Gate fires during Phase 3 before Phase 6 Step 1):
      Write a skeleton draft using the SKILL.md template — include §1-§9 headings (empty
      bodies allowed), the <!-- audit-only-below -->  anchor, and §10. Status: Draft.
   d. Append row to §8 of phase1-tech-spec.md using the 4-short-field structure:
      | # | Section | Change (≤120 chars) | Why (≤120 chars) | Affected DEC | Approved at |
      No prose, no `\n`, no bullet markers inside cells.
4. If any sub-step fails, stop and surface partial state. Do NOT silently continue.
5. Return to Phase 3 of the interview.
```

## Worked Examples

### Example 1 — Approve (clean path)

**Trigger**: spec §5.2 says "loads all items"; the dataset can be 10k+ rows; this blocks the tech choice between virtualization and pagination.

**Diff prompt to user**:
```
Proposed amendment to phase1-spec.md §5.2 Primary Workflow:
- Before: "the user opens the page and the system loads all items"
- After:  "the user opens the page and the system loads the first 20 items, lazy-loading more as the user scrolls"
- Why:    pagination strategy is a tech tradeoff; without an item-count cap the spec implies an unbounded fetch
```

User picks **Approve**. Apply Edit, re-read, append (4-short-field row — Change cell stays single-line ≤120 chars):

```
| 1 | §5.2 Primary Workflow | "loads all items" → "loads first 20 items, lazy paginate" | pagination strategy is a tech tradeoff | DEC-3 | 2026-04-24 14:22 |
```

Return to Phase 3, lock the pagination decision.

### Example 2 — Reject (user disagrees with framing)

User picks **Reject** because they actually do want all items loaded — the dataset is bounded at ~50 rows. No edit. Return to Phase 3 and lock the "load-all" decision; record the reasoning in §1 evidence.

### Example 3 — Defer

The user can't decide now and wants to think. Pick **Defer**. Add a row to `phase1-tech-spec.md` §9.1 Blocking technical questions with the unresolved spec gap. Mark the affected dimension `[??]` in progress tracking. Return to Phase 3 and continue with other dimensions.

## Edge Cases

### Multi-intent reply

**Trigger**: user replies "approve, but also change the login page wording" — bundling approval with a new edit.

**Rule**: treat the entire reply as **Reject** for the proposed diff. Restate a single revised diff that incorporates the new edit, ask again. **Never partially apply**.

Why: if you partial-apply, the §8 ledger becomes ambiguous about what the user actually approved, and the protect-files contract loses auditability.

### Multi-section amendment in one round

**Rule**: one diff per prompt. If two sections need amendment, run the Gate twice. The user might approve one and reject the other; bundling forces an all-or-nothing answer that loses information.

### Amendment overwritten by user mid-flow

**Trigger**: between your `Edit` and the `Re-read`, the user (or a hook, or a concurrent process) changes the file again.

**Behavior**: the re-read step catches this — your "After" text won't be present (or won't be in the right context). Stop. Surface what you observed: "Applied my edit to §5.2, but on re-read the file content differs from what I expected. Here's what I see now: ... — please tell me how to proceed."

### Edit succeeds, append-to-§8 fails

**Trigger**: Edit landed but writing §8 of `phase1-tech-spec.md` failed (disk error, permission, etc.).

**Behavior**: stop immediately. The state is now inconsistent — `phase1-spec.md` has the change but `phase1-tech-spec.md` does not record it. Tell the user verbatim:

```
Partial state — atomic Gate failed:
- phase1-spec.md §5.2 was edited successfully (verified by re-read).
- phase1-tech-spec.md §8 amendment row could NOT be appended ({reason}).
- Please decide: revert the spec edit, or retry the §8 append?
```

Do not retry silently. Do not proceed to Phase 3 until the user resolves.

### User wants to "approve but tweak the After text"

Treat as **Reject** (multi-intent rule). Restate the revised After text as a new single diff and run the Gate again.

## Ratchet Policy

Each amendment fragments `phase1-spec.md` slightly — every time you append a §8 row, the spec becomes a layered document. After 3 amendments in a single session, the spec is no longer a clean document and downstream readers (code-planner, reviewer gates) struggle to know which version is "current."

**Behavior**: when the 3rd Gate is about to fire, before showing the diff, surface the policy:

> "This will be the 3rd Phase 1 amendment in this session. At this point the spec has accumulated significant in-flight changes. Would you prefer to:
> - Apply this amendment and continue
> - Pause the interview, re-run req-clarifier with the accumulated context, then resume tech-interviewer with a clean spec?"

If the user picks "re-run", stop the interview and hand off; do not apply the 3rd amendment.

**In-progress draft handling** — when the user picks "re-run":
1. Rename the in-progress `phase1-tech-spec.md` to `phase1-tech-spec.draft.md` so the rubric scores, evidence, and prior decisions are preserved as scratch input for the next tech-interviewer round.
2. The renamed `.draft.md` simply sits in the session dir alongside the other artifacts — the protect-files hook never branched on `Status: Approved by user` to begin with, so the file's "draft" status is enforced by operator discipline (and by every other phase agent's `tools:` allowlist omitting Edit), not by any hook-level filename or content check.
3. The accumulated §8 entries from `phase1-tech-spec.draft.md` plus the in-flight `phase1-spec.md` amendments become the input to req-clarifier.
4. Tell the user explicitly: "Saved current draft as `phase1-tech-spec.draft.md`. After req-clarifier completes, re-invoke tech-interviewer; you can reference the draft for prior rubric scoring."

This contract works with the qqq workflow's `rewind` action: a rewind to phase 1 will not delete `phase1-tech-spec.draft.md` because it is not in the rewind target list (only `phase1-tech-spec.md` is). If the user wants a clean slate, they can manually remove the draft file.

## Why the Gate Matters Even Though No Hook Enforces It

The protect-files hook (`hooks/qqq-protect-files.sh`) does NOT inspect `phase1-spec.md` content, branch on the editing agent, or maintain any per-agent allow-list. Earlier versions of this reference described a `req-clarifier` artifact-owner branch and a `tech-interviewer` allow-list inside the hook — neither exists today (they were retired with `.qqq.lock` and the v2.3 launcher rewrite). The current hook only blocks Edit/Write/Bash against `claude-works-completed/*`, the post-merge archive.

What actually keeps `phase1-spec.md` safe from drive-by edits:

- Every phase agent except `qqq:tech-interviewer` omits `Edit(./claude-works/**)` from its `tools:` allowlist — so a downstream session physically cannot mutate `phase1-spec.md` even if it tried.
- `qqq:tech-interviewer` retains Edit access **so that this gate can rewrite the file**. There is no hook-level second line of defense; this gate is the enforcement mechanism. Free-hand edits (no diff prompt, no user approval, no §8 append) succeed silently — nothing catches them.

This is why the atomic skeleton is in `SKILL.md` (not deferred to this reference) — even if you skip reading this file, the inline skeleton must be followed. This file deepens your understanding; the skeleton is mandatory.
