---
name: ui-outline
description: "qqq:ui-outline — Convert a clarified requirement spec into a minimal HTML UI outline and iterate with the user until approved. Input: phase1-spec.md. Output: phase1-ui-outline.md + phase1-ui-outline.html in the same session directory."
argument-hint: "<path to phase1-spec.md>"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, AskUserQuestion, Bash(dirname *), Bash(basename *), Bash(date *), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: sonnet
effort: high
---

# UI Outline — Minimal HTML Wireframe from a Clarified Spec

Your mission is to produce a **low-fidelity, navigable HTML outline** that proves the information architecture and primary workflows from the frozen requirement spec, then iterate with the user on plain-text feedback until they approve it.

Core principle: **An outline is a shared artifact to agree on structure, not a production UI.** Optimize for legibility and speed of iteration, not for visual polish.

## Hard Rules

- Never modify `phase1-spec.md` — it is the frozen input artifact
- Never design brand-new features not present in the spec
- Never add production-grade styling (no frameworks, no component libraries, no icons)
- Never create a new session directory — reuse the parent of `phase1-spec.md`
- Never proceed past a draft without showing the artifact to the user and waiting for a free-text reply
- Never invent user decisions — if the user's feedback is ambiguous, ask one targeted follow-up

## Process

### Phase 0: Resolve Session Directory

The user will inject a path like `./claude-works/<YYYY-MM-DD>_<feature-slug>/phase1-spec.md`.

1. Take the argument (or the path mentioned by the user in the conversation) and compute the session directory:
   ```bash
   dirname "<injected-path>"
   ```
2. If no path is provided, stop and ask the user: "Please provide the path to the clarified spec (phase1-spec.md)."
3. All outputs for this session go under that directory.

### Phase 1: Read the Spec and State Understanding

1. Read `phase1-spec.md` fully.
2. Extract:
   - Core purpose (from section 1)
   - Target users and scenarios (from section 2)
   - Must-have features and explicit out-of-scope (from section 3)
   - Primary workflow steps (from section 6)
   - Data model entities shown in the UI (from section 5)
3. Restate your understanding back to the user in ≤10 bullets. Confirm: "Does this capture what the UI needs to show?"

If the user corrects the understanding, update it before drafting anything.

### Phase 2: Draft the Outline

Produce two files in the session directory:

**`phase1-ui-outline.md`** — the rationale document:
- Screen map (list of screens/views with 1-line purpose each)
- Navigation flow (how the user moves between screens for each must-have scenario)
- Component inventory per screen (header/list/form/modal/empty-state — low-fidelity names only)
- Open UI questions (if any)

**`phase1-ui-outline.html`** — a single self-contained HTML file:
- One `<section>` per screen, stacked vertically with clear visual separation
- Each section uses a plain `<h2>Screen Name</h2>` + short description + structural markup (`<nav>`, `<form>`, `<ul>`, `<table>`, `<button>`) with placeholder text
- Minimal inline CSS only: `max-width: 960px`, neutral background per section, dashed borders to signal "outline not design"
- No JavaScript, no external assets, no CDN links
- Include `<!-- Flow: S1 → S2 → S3 -->` HTML comments to indicate primary navigation

Keep the HTML under ~300 lines. If more is needed, prefer splitting into multiple outline cycles.

### Phase 3: Iteration Loop (Free-Text Feedback)

After writing each draft:

1. Tell the user the exact file paths you wrote.
2. Summarize what's in the draft (screens, flow, open questions) in ≤8 bullets.
3. Stop and wait for the user's plain-text reply — do not use AskUserQuestion for this loop; the user wants free-form feedback.
4. When the user replies:
   - Treat the reply as a set of diffs against the current draft.
   - Group feedback into: **structural** (add/remove/rename screens), **flow** (re-ordering or new transitions), **cosmetic** (labels, placeholder text), **out-of-scope** (production styling, real data).
   - Reject cosmetic/production-styling asks briefly ("that belongs in a later phase").
   - Re-write the two files with minimal changes that address structural/flow feedback.
5. Repeat until the user writes something that clearly means approval (e.g., "ok", "looks good", "approve", "proceed", "다음 단계로", "confirm").

If the user goes silent for the session, do not assume approval. Exit with the last draft and a note that approval is still required before Phase 2.

### Phase 4: Freeze and Hand-off

On approval:

1. Append a closing block to `phase1-ui-outline.md`:
   ```
   ---
   Status: Approved by user
   Approved at: {YYYY-MM-DD HH:MM}
   Iterations: {N}
   Next phase input: phase1-ui-outline.md + phase1-ui-outline.html
   ```
2. Print the two file paths and the single next-step command the user would run:
   ```
   qqq  # select tech-interviewer or code-planner — phase1-ui-outline.md becomes optional input
   ```
3. Stop. Do not proceed into Phase 2 work yourself.

## Output File Templates

### phase1-ui-outline.md

```markdown
# UI Outline — {Feature Title}

> Created: {YYYY-MM-DD HH:MM}
> Spec: ./phase1-spec.md
> Status: Draft | Approved

## Screen Map

| ID  | Screen          | Purpose                                   |
|-----|-----------------|-------------------------------------------|
| S1  | {name}          | {one-line purpose}                        |

## Primary Flow

1. S1 → S2 (trigger: {event})
2. S2 → S3 (trigger: {event})

## Components per Screen

### S1 — {name}
- Header: {labels}
- Main: {list / form / table / empty-state}
- Footer / CTA: {primary action}

## Open UI Questions

- [ ] {question and why it matters}

## Decisions Locked In This Cycle

- {decision}: {rationale}
```

### phase1-ui-outline.html

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>UI Outline — {feature}</title>
  <style>
    body { font: 14px/1.5 system-ui, sans-serif; max-width: 960px; margin: 2rem auto; color: #222; }
    section { border: 1px dashed #888; padding: 1rem 1.25rem; margin-bottom: 1.5rem; background: #fafafa; }
    section h2 { margin-top: 0; }
    .hint { color: #666; font-size: 12px; }
    nav, form, ul, table { margin: 0.5rem 0; }
  </style>
</head>
<body>
  <h1>UI Outline — {feature}</h1>
  <p class="hint">Low-fidelity wireframe. Structure only — no production styling.</p>

  <!-- Flow: S1 → S2 → S3 -->

  <section id="s1">
    <h2>S1 — {screen name}</h2>
    <p class="hint">{purpose}</p>
    <nav>{placeholder nav items}</nav>
    <!-- main content placeholder -->
  </section>

  <section id="s2">
    <h2>S2 — {screen name}</h2>
    <p class="hint">{purpose}</p>
    <!-- form/list placeholder -->
  </section>
</body>
</html>
```
