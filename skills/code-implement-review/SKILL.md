---
name: code-implement-review
description: "qqq:code-implement-review — Review the current working diff by trying Codex CLI (`codex exec`) first, then falling back to Claude review only if Codex is unavailable or fails for infrastructure reasons. Persist the review artifact and return a structured OKAY/REJECT verdict keyed to file:line."
argument-hint: "<labeled prompt: Plan / Session dir / Round / ...>  (legacy: bare absolute plan path)"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Bash(git *), Bash(ls *), Bash(find *), Bash(dirname *), Bash(basename *), Bash(date *), Bash(wc *), Bash(codex *), Bash(which codex), Write(./phase3-*.md), Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**)
model: sonnet
effort: high
---

# Code Implement Review

Review one thing only: the current implementation diff for the approved plan at `phase2-code-plan.md`.

Codex CLI is the primary reviewer. Claude fallback is allowed only when Codex is unavailable or fails for infrastructure reasons such as missing CLI, auth failure, quota/rate-limit, model unavailable, or transport/runtime failure.

Progressive disclosure:
- Before any action, read [references/codex-primary.md](references/codex-primary.md).
- Read [references/fallback-policy.md](references/fallback-policy.md) only if Codex is missing or the Codex attempt fails.
- Read [references/claude-fallback.md](references/claude-fallback.md) only if fallback is allowed.
- Read [references/verdict-shapes.md](references/verdict-shapes.md) only when composing the final response.

## Input Contract

Callers (notably `qqq:code-implement` round dispatch) pass a labeled prompt. Parse the following labels case-insensitively, one per line, before any review work:

```
Plan: <absolute path to phase2-code-plan.md>           # required
Session dir: <absolute path>                           # required
Round: <integer k>                                     # required
Codex artifact: <abs>/phase3-codex-review-{k}.md       # required when Codex path is taken
Claude fallback artifact: <abs>/phase3-claude-review-{k}.md   # required when fallback is taken
Review policy: codex-first                             # informational
Plan fingerprint: sha256:<digest>                      # optional, audit aid
Implementation log: <abs>/phase3-implement-log.md      # optional, for cross-reference
```

Two distinct artifact labels (one per engine) are mandatory because the engine path determines the filename (`phase3-codex-review-*.md` vs `phase3-claude-review-*.md`). A single `Artifact:` field would silently mismatch on fallback.

**Backward compatibility**: If the caller's prompt is a bare absolute path with no `Plan:` label, treat it as legacy: derive `Session dir = dirname(<path>)`, scan existing `phase3-*-review-*.md` to compute `Round = max+1` (default 1), and synthesize the artifact paths from `Session dir` + `Round`. Log the legacy fallback in the artifact header so the audit trail makes the input shape clear.

## Hard Rules

- Codex-first is mandatory unless `which codex` fails.
- Do not use Claude fallback because Codex gave a weak answer or because you prefer to review it yourself.
- Never edit source files; reviewer output is advisory only.
- Persist exactly one round artifact per review round:
  - Codex primary: write to the `Codex artifact` path (pattern `phase3-codex-review-{k}.md`)
  - Claude fallback: write to the `Claude fallback artifact` path (pattern `phase3-claude-review-{k}.md`)
- Each artifact must identify the authoring engine in its header.
- Final verdict must be exactly `OKAY` or `REJECT`.

## Workflow

1. Parse the labeled prompt (or legacy bare path) to resolve plan, session dir, round, and the two engine-keyed artifact paths.
2. Read local intent:
   - `phase2-code-plan.md` (from the `Plan` label)
   - `phase1-spec.md` (sibling)
   - current diff and, when needed, the most changed files
3. Try Codex first using `references/codex-primary.md`. Use the `Codex artifact` label as the destination path; do not recompute it.
4. If Codex fails, consult `references/fallback-policy.md`.
5. If fallback is allowed, run the Claude-native review in `references/claude-fallback.md`. Use the `Claude fallback artifact` label as the destination path.
6. Use `references/verdict-shapes.md` to return the final structured verdict.

## Notes

- Prefer the real diff over speculative concerns.
- If the diff is huge, narrow context but keep the verdict grounded.
- If Codex or Claude fallback produces malformed review output, return `REJECT`.
