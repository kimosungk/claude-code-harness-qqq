# Clarification Cheatsheet

On-demand reference for `qqq:clarify-requirement`. Load only when SKILL.md routes you here.

---

## Scope guard (most important)

This skill clarifies **user-facing requirements only**. If the user mentions performance numbers, security implementation, API/DB choice, browser/device support, or internal architecture:

- Acknowledge briefly: "Noted — I'll record that for the implementation-planning phase."
- Log it **verbatim** under §7 Deferred Decisions (category: technical).
- Steer back to the current user-facing dimension.
- **Do not** ask "What's the target latency?" / "Which database?" / "Which browsers?" / "What's the throughput target?" — those are planner-phase questions.

**Only exception**: if the technical constraint has a user-visible consequence the user seems unaware of, flip it back to a user question — e.g., "If this might take several seconds, what should the user see while waiting?"

---

## 6 Socratic question types — one-line patterns

1. **Clarifying** — "You said X — what specifically do you mean by ...?"
2. **Probing assumptions** — "You seem to assume X — what if X isn't true?"
3. **Probing reasons** — "Why do you believe that's the best approach?"
4. **Questioning viewpoints** — "From X's perspective, how would this look?"
5. **Probing implications** — "If you do that, what happens to ...?"
6. **Meta** — "Are we asking the right question here?"

Always mix at least 1 Socratic question per round; never run a round of pure direct questions.

---

## 5 dimensions — 1 direct + 1 Socratic each

### 1. Purpose (Why) — always required
- Direct: "What core problem does this feature solve for the user?"
- Socratic: "If this feature didn't exist and users only had today's workflow, what would go wrong for them?"

### 2. Users & Scenarios (Who & When)
- Direct: "Who are the primary users, and when in their workflow do they reach for this?"
- Socratic: "Would a first-time user and a daily power user have the same needs? If different, how?"
- N/A: pure backend with no observer at all.

### 3. Scope (What) — always required
- Direct: "Where does this feature end? What does it explicitly NOT do for the user?"
- Socratic: "If you had to keep just one user-visible capability, what would you keep?"

### 4. User-Visible Behavior
- Direct: "Walk me through what a user does, step by step, and what they see after each step."
- Socratic: "If step 2 fails, what does the user see? Do they start over, or can they resume?"
- N/A: pure backend job with no operator UI.

### 5. Edge Cases (user-perspective)
- Direct: "What should the user see when there is no data, the network is slow, or they trigger this repeatedly?"
- Socratic: "What's the worst thing a user could experience with this feature, from their seat?"
- N/A for read-only views: only check empty results, large result sets, and loading state.

---

## Situational handling

### "I don't know" / "I'll decide later"
Don't push for a direct answer:
1. Present 2-3 options via AskUserQuestion: "Approach A or B — which feels more natural?"
2. Reframe: "'I don't know' can mean there are multiple valid options. May I propose a few?"
3. If still uncertain, mark the dimension `[??]` (blocking open question) and move on.

### Mid-stream requirement changes
- "Earlier you said X, but now it sounds like Y. What changed in your thinking?"
- Once confirmed, review previously settled answers that may be affected by the change.

### User references existing documents
- Read the document, summarize key points.
- Then ask: "Which parts of this document still apply to the current requirement, and which need to change?"

### User raises a technical constraint
Apply the **Scope guard** above. Acknowledge → log verbatim to §7 Deferred Decisions → steer back to user-facing. Never probe for concrete numbers or alternatives.

### User wants to move fast
- Lean on AskUserQuestion with options for rapid decisions.
- Use confirmation questions ("I understood X — correct?") on clear areas.
- Reserve Socratic questions for ambiguous core areas only.
