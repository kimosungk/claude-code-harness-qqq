# Socratic Question Shapes — for L3 Escalation Rounds Only

**When to use this file**: only when the decision rubric (`decision-rubric.md`) classifies a decision as **L3 — full escalation** and `AskUserQuestion` with structured options does not give you enough room to explore the tradeoff. For L1 (decide autonomously) and L2 (single confirmation question), do not load these techniques.

The Socratic shapes below help **structure a discussion** with the user when the rubric is genuinely tied or evidence is too thin to lock a decision. They are not a license to interrogate the user on decisions you could have made yourself — that is anti-pattern usage of this file.

---

## Framing

In tech-interviewer's context, you usually know more than the user about the codebase, library ecosystems, and the rubric scoring. Socratic questions therefore play a different role than in `req-clarifier`:

- **In `req-clarifier`**: surface gaps in the user's *own* requirements.
- **In `tech-interviewer` (here)**: surface the *tradeoff* the user must own — because either branch has a real cost the user has not yet weighed.

The user is the decision authority for tradeoffs you cannot reduce. You are the analyst that frames the choice cleanly.

---

## 6 Socratic Question Types — Tech Examples

### 1. Clarifying Questions

Pin down a vague tech term the user used so the rubric can score it.

**Pattern**: "You said X — what specifically do you mean by..."

**Examples**:
- "You said the alarm pipeline should be 'real-time' — do you mean p99 latency under 500ms (WebSocket / SSE territory), or 'updates without manual refresh' (polling-friendly)? The cost difference is significant."
- "You mentioned 'simple state' for the new panel — do you mean ≤3 fields with no derived state (Context API fits), or 'simple to use' even though there's cross-component sharing (Zustand fits)?"

### 2. Probing Assumptions

Surface a hidden premise behind the user's preferred option.

**Pattern**: "You seem to assume X — what if X isn't true?"

**Examples**:
- "You're leaning toward storing alarm history in IndexedDB. That assumes it persists across devices is not required. The spec doesn't say either way — should we lock 'per-device only', or do we need a server-side store?"
- "Picking gRPC here assumes the frontend can run a gRPC-Web proxy. Our current deployment doesn't have one — was that part of the plan, or should we stay on REST?"

### 3. Probing Reasons & Evidence

Make sure a stated tech preference has substance behind it. Use sparingly — this question shape can feel adversarial when the user is confident.

**Pattern**: "What evidence makes that the right call here?"

**Examples**:
- "You'd prefer Redux Toolkit. The repo currently uses Zustand at `src/store/alarmStore.ts:8`. What's making RTK the better fit for *this* feature specifically?"
- "Suggesting GraphQL — is that to solve a known over-fetch problem on a specific endpoint, or is it a general preference? The cost (schema, codegen, server work) is significant either way."

### 4. Questioning Viewpoints

Surface a stakeholder whose constraints the current proposal ignores.

**Pattern**: "From X's perspective, how does this look?"

**Examples**:
- "This works for the dev team. From the on-call engineer's perspective at 3am — when this WebSocket connection drops, what do they see in the logs and how do they recover it?"
- "Adopting tRPC simplifies the frontend. From a future Android client's perspective — would they need to call this same API? If so, REST or gRPC may serve us better."

### 5. Probing Implications

Predict ripple effects of a tech choice the user is leaning toward.

**Pattern**: "If you do that, what happens to...?"

**Examples**:
- "If we put the alarm cache in Zustand persist (localStorage), what happens to it when the user logs out on a shared workstation?"
- "If we make this endpoint server-rendered, what happens to the existing client-side filter UI that depends on having all rows in memory?"

### 6. Meta Questions

Reflect on whether you and the user are debating the right thing.

**Pattern**: "Are we sizing this decision correctly?"

**Examples**:
- "We've spent three rounds on whether to use Postgres triggers vs application-side hooks. Both are reversible decisions if we keep the data shape stable. Should we just pick one and revisit if it bites us?"
- "This feels like a 'best-practice' debate rather than a project-specific tradeoff. Do you have a strong preference, or should I lock the option that fits the existing repo pattern and move on?"

---

## Situational Guide

### When the user says "I don't know"

Don't push them for an opinion they don't have. Re-anchor on the rubric:

- "That's fine. The rubric scores option A higher on maintainability and integration-fit; B is faster but the perf gain is theoretical at our load. Want me to lock A and revisit if perf becomes an issue?"
- "Two viable paths. I'd default to <X> based on rubric scoring. If you want to choose differently, here are the implications: ..."
- **[Record as open question]** "If picking now is risky without more data, we can defer this to §8 Open Technical Questions and let `code-planner` see both options."

### When the user changes their mind mid-round

- "Earlier we leaned toward X based on <evidence>. The new direction implies <new constraint> — should I rescore against the rubric and report back, or do you want to lock Y now?"
- "The new direction is promising. Does it affect anything we already locked? Specifically: <list affected dimensions>."

### When the user references existing documents or prior decisions

- "I'll read it. Which section is the load-bearing one for this decision?"
- After reading: "The doc says <X>. Does that still hold for the current feature, or is the constraint relaxed?"

### When the user raises a non-technical concern (UX, copy, scope)

A user-facing concern is not in tech-interviewer's scope. Two paths:

- If the concern blocks a tech decision and a small spec change would unblock it → trigger the **Amendment Gate** (`amendment-gate.md`).
- If the concern is a new feature or UX redesign → stop and route to `req-clarifier`. Do not absorb it into the tech spec.

Only exception: when a tech-side constraint has a user-visible consequence the user has not considered, flip it back to a user-facing question — e.g., "This API is paginated; the spec says results render instantly. The mismatch is real. Want to amend the spec to 'first page renders instantly' (Amendment Gate), or change the tech approach?"

### When the user wants to move fast

Trust the rubric. Default behavior:

- Score, declare the L1/L2/L3 tier, and if L1 just decide — that's what speed looks like.
- For L2, frame the single confirmation question concisely with rubric scores; one round.
- Reserve Socratic questioning for genuine L3.

If the user explicitly says "just decide", enable a session-level fast-path: still write the rubric scores for each subsequent L2 decision, but skip the Confirm/Discuss prompt. **Mark these decisions as `Decided: With user (fast-path enabled at round N)` — distinct from `Autonomously` and `With user (confirmed)`.** This preserves the audit trail: at Phase 5 the user can see which decisions were pre-authorized in bulk vs which ones the agent decided alone.

L1 decisions remain unaffected. L3 (truly tied / thin evidence) still escalates — the fast-path does not override safety checks. The user can disable the fast-path mid-session by saying "stop fast-path" or similar; from that point forward L2 decisions revert to the Confirm/Discuss prompt.

### When you and the user disagree

You are the analyst, not the authority. If the user picks an option you scored lower:

- Ask once: "Could you share what's driving that — is there context I'm missing in the rubric scoring?" (Probing Reasons, used carefully.)
- If the answer surfaces context you missed → rescore, possibly change tier, possibly agree.
- If the answer is "I just prefer it" → lock the user's choice, mark `Decided: With user (discussed)`, record the rubric scores in evidence so the next maintainer can see the rationale.

The §6 Risk register is the place to log known costs of the chosen path.
