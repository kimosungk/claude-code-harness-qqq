# Claude Fallback

Read this only if fallback is allowed by `fallback-policy.md`.

## Review Scope

Review the same inputs Codex would have reviewed:
- `phase1-spec.md`
- `phase2-code-plan.md`
- `git diff --stat`
- `git diff`

Optionally read 1-3 changed files when the diff is ambiguous.

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
- fallback trigger
- run time
- source plan path

Then write the raw Claude review body below the header.
