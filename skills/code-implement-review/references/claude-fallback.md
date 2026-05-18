# Claude Fallback

Read this only if fallback is allowed by `fallback-policy.md`.

## Review Scope

Review the same inputs Codex would have reviewed (scope: working-tree):
- `phase1-spec.md`
- `phase2-code-plan.md`
- `git status --porcelain` (tracked + untracked overview)
- `git diff --stat HEAD` (tracked changes summary; staged + unstaged combined)
- `git diff HEAD` (tracked changes full diff; staged + unstaged combined)

Untracked file bodies are intentionally not read by default. Optionally read 1-3 changed files when the diff is ambiguous, or read an untracked file's content only if the review specifically needs it.

## Requirements

- Apply the same four lanes as the Codex prompt:
  - Architecture
  - Correctness & Testability
  - Security
  - Maintainability
- Return only `OKAY` or `REJECT`
- Keep findings keyed to `file:line`
- Do not edit source files

## Artifact

Write `phase3-claude-review-{k}.md` with a header that includes:
- reviewer engine: Claude
- mode: fallback
- fallback trigger (the failure category from `codex-failure-stub.md`, e.g., `auth`, `quota`)
- review scope (mirror the value from the input contract; today always `working-tree`)
- run time
- source plan path

Then write the raw Claude review body below the header.
