---
name: rebase-conflict-resolve
description: "qqq:rebase-conflict-resolve — Resolve an in-progress git rebase conflict by trying Codex CLI (`codex exec`) headlessly in `workspace-write` mode first, then falling back to Claude edits only if Codex is unavailable or fails for infrastructure reasons. Persist the Codex attempt and return a strict RESOLVED or BLOCKED verdict with git-state evidence."
argument-hint: "<path to phase2-code-plan.md or session dir> [worktree=/abs/path] [base_branch=name]"
disable-model-invocation: false
allowed-tools: Read, Grep, Glob, Edit, Bash(git *), Bash(ls *), Bash(find *), Bash(dirname *), Bash(basename *), Bash(date *), Bash(pwd), Bash(which codex), Bash(codex *), Write(./rebase-conflict-*.md), Write(./claude-works/**), Write(./claude-works-completed/**), Write(../claude-works/**), Write(../claude-works-completed/**), Write(../../claude-works/**), Write(../../claude-works-completed/**), Write(../../../claude-works/**), Write(../../../claude-works-completed/**)
model: sonnet
effort: high
---

# Rebase Conflict Resolve

Resolve one thing only: an already in-progress `git rebase origin/<base>` (typically `main`, but any branch is valid) that stopped on conflicts.

Codex CLI is the primary solver. Claude fallback is allowed only when Codex is unavailable or fails for infrastructure reasons such as missing CLI, auth failure, quota/rate-limit, model unavailable, or transport/runtime failure.

Progressive disclosure:
- Before any action, read [references/codex-primary.md](references/codex-primary.md).
- Read [references/fallback-policy.md](references/fallback-policy.md) only if Codex is missing or the Codex attempt fails.
- Read [references/claude-fallback.md](references/claude-fallback.md) only if fallback is allowed.
- Read [references/verdict-shapes.md](references/verdict-shapes.md) only when composing the final response.

## Hard Rules

- The rebase must already be in progress. If not, return `BLOCKED`.
- Codex-first is mandatory unless `which codex` fails.
- Do not use Claude fallback because Codex gave a weak answer or because you prefer to solve it yourself.
- Do not commit, push, start a new merge, or abort the rebase.
- Keep scope tightly limited to the active conflict set.
- Persist artifacts in the session directory:
  - `rebase-conflict-codex-{k}.md`
  - `rebase-conflict-claude-fallback-{k}.md` when fallback is used
- Final verdict must be exactly `RESOLVED` or `BLOCKED`.

## Workflow

1. Resolve inputs from `$ARGUMENTS`.
   - Accept a plan path or session dir.
   - Accept optional `worktree=/abs/path` and `base_branch=name`.
   - Session dir is the plan parent or the provided dir.
   - Worktree is `worktree=` when present, otherwise derive from git.

2. Preflight.
   - Verify whether `codex` is on PATH.
   - Verify the worktree has an active rebase.
   - Capture current conflict state with `git status --short` and `git diff --name-only --diff-filter=U`.
   - If there are no unmerged files, return `BLOCKED`.
   - Determine round `k` from existing `rebase-conflict-codex-*.md`.

3. Read local intent.
   - `phase1-spec.md` when present
   - `phase2-code-plan.md` when present
   - `phase1-ui-outline.md` when present
   - conflicted files and current git state

4. Try Codex first.
   - Follow `references/codex-primary.md`.
   - Persist the Codex attempt even if it fails.
   - If Codex fails for an allowed infrastructure reason, continue to Claude fallback.
   - Otherwise stop with `BLOCKED`.

5. Claude fallback only when allowed.
   - First read `references/fallback-policy.md`.
   - If fallback is allowed, read and follow `references/claude-fallback.md`.

6. Validate the actual git state.
   - Re-check `git status --short`, unmerged files, and `git diff --check`.
   - `RESOLVED` only when there are no unmerged files and the rebase is no longer active.
   - Otherwise return `BLOCKED`.
   - Use `references/verdict-shapes.md` for the exact output shape.

## Notes

- Prefer repository evidence over speculative merge choices.
- If the semantic choice is ambiguous even after reading spec/plan, stop with `BLOCKED`.
- If Codex or Claude fallback makes partial progress, report that progress but still return `BLOCKED`.
