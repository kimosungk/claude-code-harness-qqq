# Verdict Shapes

Use the final structured verdict below whether the review came from Codex or Claude fallback.

## OKAY / REJECT

```markdown
**Verdict: OKAY**

or

**Verdict: REJECT**

## Summary
- Architecture: {Pass / Fail + one-line reason}
- Correctness & Testability: {Pass / Fail + one-line reason}
- Security: {Pass / Fail + one-line reason}
- Maintainability: {Pass / Fail + one-line reason}

## Issues (if REJECT; omit if OKAY)

- [CRITICAL] {file:line} — {issue}
  Fix: {concrete suggestion}
- [HIGH] {file:line} — {issue}
  Fix: {concrete suggestion}
- [MEDIUM] ...
- [LOW] ...

## Evidence
- Reviewer engine: {Codex | Claude}
- Review artifact: ./phase3-{codex|claude}-review-{k}.md
```

## Translation Rules

- `OKAY` only when no blocking issues exist
- Any CRITICAL/HIGH issue means `REJECT`
- Malformed reviewer output means `REJECT`
