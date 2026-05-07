---
name: code-implement-review
description: "qqq:code-implement-review — Review the current working diff by trying Codex CLI (`codex exec`) first, then falling back to Claude review only if Codex is unavailable or fails for infrastructure reasons. Persist the review artifact and return a structured OKAY/REJECT verdict keyed to file:line."
argument-hint: "<absolute path to phase2-code-plan.md>"
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

## Hard Rules

- Input is the absolute path to `phase2-code-plan.md`; derive the session dir from it.
- Codex-first is mandatory unless `which codex` fails.
- Do not use Claude fallback because Codex gave a weak answer or because you prefer to review it yourself.
- Never edit source files; reviewer output is advisory only.
- Persist exactly one round artifact per review round:
  - Codex primary: `phase3-codex-review-{k}.md`
  - Claude fallback: `phase3-claude-review-{k}.md`
- Each artifact must identify the authoring engine in its header.
- Final verdict must be exactly `OKAY` or `REJECT`.

## Workflow

1. Resolve the input plan path and session dir.
2. Read local intent:
   - `phase2-code-plan.md`
   - `phase1-spec.md`
   - current diff and, when needed, the most changed files
3. Try Codex first using `references/codex-primary.md`.
4. If Codex fails, consult `references/fallback-policy.md`.
5. If fallback is allowed, run the Claude-native review in `references/claude-fallback.md`.
6. Use `references/verdict-shapes.md` to return the final structured verdict.

## Notes

- Prefer the real diff over speculative concerns.
- If the diff is huge, narrow context but keep the verdict grounded.
- If Codex or Claude fallback produces malformed review output, return `REJECT`.
