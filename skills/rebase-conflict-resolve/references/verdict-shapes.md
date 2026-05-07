# Verdict Shapes

Run final validation first:

```bash
git -C "<worktree>" status --short
git -C "<worktree>" diff --name-only --diff-filter=U
git -C "<worktree>" diff --check
```

Also verify whether the rebase is still active by checking `rebase-merge` / `rebase-apply`.

Return:
- `RESOLVED` only if there are no unmerged files and the rebase is no longer active
- otherwise `BLOCKED`

## RESOLVED

```markdown
**Verdict: RESOLVED**

## Summary
- Rebase conflict was resolved and the rebase is no longer active.

## Evidence
- Worktree: <worktree>
- Raw Codex response: ./rebase-conflict-codex-{k}.md
- Claude fallback log: ./rebase-conflict-claude-fallback-{k}.md (omit if not used)
- Final `git status --short`:
  <trimmed output>
```

## BLOCKED

```markdown
**Verdict: BLOCKED**

## Summary
- <why it remains blocked>

## Evidence
- Worktree: <worktree>
- Raw Codex response: ./rebase-conflict-codex-{k}.md
- Claude fallback log: ./rebase-conflict-claude-fallback-{k}.md (omit if not used)
- Remaining unmerged files:
  <list or `(none)`>
- Final `git status --short`:
  <trimmed output>
```
