# Claude Fallback

Read this only if fallback is allowed by `fallback-policy.md`.

## Loop

1. Re-read current conflict state:
   ```bash
   git -C "<worktree>" status --short
   git -C "<worktree>" diff --name-only --diff-filter=U
   ```
2. For each conflicted file:
   - inspect the working file with conflict markers
   - inspect stage versions:
     ```bash
     git -C "<worktree>" show ":1:<path>"
     git -C "<worktree>" show ":2:<path>"
     git -C "<worktree>" show ":3:<path>"
     ```
   - make the smallest safe edit
   - stage it:
     ```bash
     git -C "<worktree>" add -- "<path>"
     ```
3. After the current set:
   ```bash
   git -C "<worktree>" diff --check
   git -C "<worktree>" rebase --continue
   ```
4. If another conflict appears, repeat.

## Hard Rules

- Do not rewrite unrelated code for style/cleanup
- Do not touch phase documents
- Do not create new helper abstractions unless the conflict truly requires it
- If the semantic choice is ambiguous even after reading spec/plan, stop with `BLOCKED`

## Fallback Log

Write `rebase-conflict-claude-fallback-{k}.md` with:
- fallback trigger
- files edited
- commands run
- whether `git rebase --continue` completed or stopped on new conflicts
