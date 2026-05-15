---
name: merge-mr
description: "qqq:merge-mr — Thin wrapper around glab/gh for the qqq Phase 3 merge step. Detects host from origin URL, commits any uncommitted phase artifacts, archives `claude-works/<slug>/` to `claude-works-completed/<slug>/`, pushes the current branch, creates an MR/PR (or finds the existing one) with a description rendered from phase0/1/2/3 artifacts, then merges it. No quality gates beyond what glab/gh enforce. Quality assurance is the PR reviewer's responsibility (D1−)."
argument-hint: "[session_dir] [--dry-run] [--no-merge]"
disable-model-invocation: false
allowed-tools: Read, Glob, Grep, Bash(git *), Bash(glab *), Bash(gh *), Bash(awk *), Bash(sed *), Bash(jq *), Bash(basename *), Bash(dirname *), Bash(pwd), Bash(wc *), Bash(head *), Bash(which *), Bash(find *), Bash(sort *), Bash(mkdir *), Bash(stat *), Bash(test *), AskUserQuestion
model: sonnet
effort: low
---

# Merge MR/PR — Thin Wrapper, No Quality Gates

This skill is the qqq Phase 3 merge step. It assumes:

- `phase3-implement-log.md` is complete (or the user knowingly merges without it).
- A human reviewer has already approved the change on the MR/PR web UI.
- Quality assurance is the PR reviewer's responsibility — this skill validates *nothing* beyond what `glab` / `gh` enforce on their own (D1− "검증 없는 wrapper").

Reference (deprecated, do not reuse): `scripts/lib/merge-protocol.sh`, `scripts/lib/mr-create.sh`, `scripts/lib/merge-archive.sh`. This skill replaces all three with a much thinner contract.

## Hard Rules

- Must run from inside a worktree (not the main checkout). Refuse otherwise.
- Detect host from `git remote get-url origin`. URL containing `gitlab` (any subdomain or self-hosted instance) → `glab`. URL containing `github` (incl. GitHub Enterprise like `github.<corp>.com`) → `gh`. Anything else → `BLOCKED`.
- Push the current branch only. Never push directly to `main` / `master` / `trunk`.
- Never force-push, amend commits, or skip hooks.
- Read-only inputs: phase artifacts under the resolved session dir.
- `--no-merge` stops after MR/PR creation; `--dry-run` prints planned actions without push/create/merge.
- On unrecoverable git state (detached HEAD, in-progress rebase/merge/cherry-pick) → stop.
- Unrelated uncommitted files (not under the session dir) → **warn only**, do not stop. The user is responsible for what they merge (D1− principle).
- **Host enforcement assumption**: this skill does not validate review approval state. It assumes the host has branch protection / required-approvals configured. If the host accepts a merge from this skill, the operator implicitly attested the MR/PR was reviewed. See `MIGRATION_PLAN.md §9.4` for the trade-off.

## Inputs

- `$ARGUMENTS` may contain:
  - A session dir path (`claude-works/<date_slug>` inside the current worktree). If absent, resolve to the most-recently-modified session under `claude-works/` in the current worktree.
  - `--dry-run` — print actions, do nothing.
  - `--no-merge` — push + create MR/PR, do not merge.

## Process

### 1. Preflight

1. `pwd` and `git rev-parse --show-toplevel` — confirm a git repo and capture the worktree root.
2. `git rev-parse --git-common-dir` vs `git rev-parse --git-dir` — if equal, this is the main checkout. Refuse with: `BLOCKED: merge-mr must run inside a worktree, not the main checkout`.
3. `git status --porcelain=v2 --branch` — capture branch + state. Refuse if:
   - HEAD is detached
   - A rebase, merge, or cherry-pick is in progress (`.git/REBASE_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`)
   - Branch is `main` / `master` / `trunk`
4. `git remote get-url origin` — substring match:
   - URL contains `gitlab` → host=GitLab, CLI=`glab` (covers gitlab.com + self-hosted instances)
   - URL contains `github` → host=GitHub, CLI=`gh` (covers github.com + GitHub Enterprise)
   - Anything else (gitea, codeberg, bitbucket, raw ssh) → `BLOCKED: unsupported host — merge manually`
5. `which <cli>` — refuse with install instructions if missing.
6. **Default base branch resolution** (try in order, stop at first success):
   1. `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`
   2. `git ls-remote --symref origin HEAD | awk '/^ref:/ {sub(/^refs\/heads\//,"",$2); print $2; exit}'`
   3. Host CLI lookup:
      - GitLab: `glab repo view --output json | jq -r .default_branch`
      - GitHub: `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`
   4. Ask the user via `AskUserQuestion`. Refuse to guess (`main` vs `master` is not a safe assumption).

### 2. Resolve Session Directory

The skill must be **idempotent**: a user may invoke `--no-merge` first (archiving the session, creating the MR/PR), then re-invoke without `--no-merge` to merge. On the second invocation the session dir has already moved to `claude-works-completed/`.

1. If `$ARGUMENTS` names a directory anywhere under `<worktree>/**/claude-works/` *or* `<worktree>/**/claude-works-completed/`, use it.
2. Otherwise pick the most-recently-modified subdir found via a single `find` across **both** trees (`find <worktree> -type d \( -path '*/claude-works/*' -o -path '*/claude-works-completed/*' \) -mindepth 2 -maxdepth 6`), then sort by mtime and pick the newest.
3. Slug = basename of the session dir (e.g. `2026-05-15-foo-bar`).
4. Record whether the resolved session is *already archived* (under `claude-works-completed/`). If yes, step 4 (Archive) is a no-op.
5. Warn (do not refuse) if `phase3-implement-log.md` is missing — the user may be merging an artifact-less branch.

### 3. Stage Pending Phase Artifacts

1. `git status --porcelain` filtered to `phase*-*.md` and `phase*-*.json` under the session dir.
2. If any are uncommitted (untracked or modified), ask once via `AskUserQuestion`:
   - **Commit phase artifacts as "qqq: <slug> archive session artifacts"** (default Yes)
   - **Skip** (proceed; the MR/PR won't include them)
3. Other uncommitted files anywhere in the worktree: print a one-line warning (`unrelated uncommitted changes detected — they will not be in the MR/PR`) and proceed. Do not stage them.

### 4. Archive Session to claude-works-completed

This step makes `claude-works-completed/<slug>/` the canonical post-merge location (Q2 frozen scope). It must run **before push** so the archive ends up in the same MR/PR.

1. **Skip silently** if the resolved session dir already lives under `claude-works-completed/` (step 2 already detected this — idempotent re-invoke).
2. Compute the destination: if the session is at `<parent>/claude-works/<slug>/`, the destination is `<parent>/claude-works-completed/<slug>/`.
3. **Collision pre-check**: if the destination already exists (file or directory), stop with `BLOCKED: archive destination exists at <path> — manual cleanup required`. Do not overwrite.
4. Ensure the parent of the destination exists: `mkdir -p <parent>/claude-works-completed`.
5. Ask once via `AskUserQuestion`: **Archive `claude-works/<slug>` → `claude-works-completed/<slug>` now?** (default Yes). If declined, proceed without archiving (the artifacts stay in `claude-works/`).
6. If accepted: `git mv <parent>/claude-works/<slug>/ <parent>/claude-works-completed/<slug>/` followed by `git commit -m "qqq: <slug> archive session to claude-works-completed"`. Single commit, no `--no-verify`.

### 5. Push the Branch

1. `git push -u origin <branch>` — no `--force`, no `--no-verify`.
2. If push fails (non-fast-forward, hook rejection), surface stderr verbatim and stop. Do not retry.

### 6. Find or Create the MR/PR

#### GitLab

```bash
existing=$(glab mr list --source-branch "$branch" --output json 2>/dev/null | jq -r '.[] | select(.state=="opened") | .iid' | head -1)
```

- If `$existing`, capture iid + URL via `glab mr view "$existing" --output json`.
- Else `glab mr create --source-branch "$branch" --target-branch "$default_branch" --title "$slug" --description "$rendered" [--label …] [--assignee …]`.

Default target branch = `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'` (typically `main`).

#### GitHub

```bash
existing=$(gh pr list --head "$branch" --state open --json number,url --jq '.[0].number')
```

- If `$existing`, capture number + URL via `gh pr view "$existing" --json number,url`.
- Else `gh pr create --base "$default_branch" --head "$branch" --title "$slug" --body "$rendered"`.

### 7. Description Rendering (only when creating)

Body composed in this order. Each section uses `head -n 30` from the artifact, with `… (truncated — N more lines in <file>)` appended when the file is longer.

```markdown
{Closes #<iid> if phase0-issue.md has an `iid:` frontmatter field}

## Phase 0 — Issue
{phase0-issue.md head, or "N/A"}

## Phase 1 — Clarified Spec
{phase1-spec.md head, or "N/A"}

## Phase 1 — Tech Spec
{phase1-tech-spec.md head, or "N/A — not consulted"}

## Phase 1 — NLTP
{phase1-nltp.md head, or "N/A — not consulted"}

## Phase 1 — UI Outline
{phase1-ui-outline.md head, or "N/A — not consulted"}

## Phase 2 — Plan Summary
{phase2-code-plan.md head, or "N/A"}

## Phase 3 — Implementation Log
{phase3-implement-log.md head, or "N/A"}

---
*Generated by qqq:merge-mr. Full artifacts in `claude-works-completed/<slug>/` post-merge.*
```

**Byte cap**: after rendering, if the body exceeds **65536 bytes** (64 KiB), hard-truncate to 65384 bytes and append `\n\n… (body truncated at 64 KiB — see session dir for full artifacts)\n` (152 bytes). Single-pass byte truncate is sufficient — no line-budget loop needed.

**Labels and assignees**: when `phase0-issue.md` frontmatter has YAML inline arrays `labels: [...]` / `assignees: [...]`, propagate them as CLI flags:

- GitLab (`glab mr create`): `--label "a,b"` and `--assignee "x,y"` (comma-separated).
- GitHub (`gh pr create`): `--label "a" --label "b"` (repeated) and `--assignee "x" --assignee "y"` (repeated). `gh pr create` supports `--assignee` directly per the gh manual; no post-create `gh pr edit` is needed.

### 8. Merge (unless --no-merge)

#### GitLab

```bash
glab mr merge "$iid" --squash --remove-source-branch --yes
```

If the MR is not mergeable (conflicts / draft / approvals missing / pipeline failing), surface the host's error verbatim and stop. Do not retry, do not resolve.

#### GitHub

```bash
gh pr merge "$num" --squash --delete-branch
```

Same failure handling.

### 9. Final Output

Single block printed to the user:

```
verdict: MERGED | CREATED-ONLY | DRY-RUN | BLOCKED
host: gitlab | github
mr/pr: <url>
branch: <name> → <default_branch>
session: <session_dir>
next: claude rm <session_id>   # if you want to drop the worktree
```

## Failure Recovery

| Trigger | Action |
|---|---|
| Main checkout, not worktree | `BLOCKED: must run inside a worktree` |
| Detached HEAD / in-progress rebase or merge or cherry-pick | `BLOCKED: unexpected git state — resolve before merging` |
| `glab` / `gh` missing | `BLOCKED: install <cli>` |
| Unsupported origin (not gitlab/github) | `BLOCKED: unsupported host — merge manually` |
| Default base branch cannot be resolved through any of the 4 fallbacks | `BLOCKED: cannot determine base branch — pass --base explicitly` |
| Push rejected (non-fast-forward, pre-push hook reject) | Surface stderr verbatim, stop. User resolves and re-invokes. |
| MR/PR not mergeable (conflicts, draft, missing approvals, failing pipeline) | Surface host message verbatim, stop. User resolves on web UI and re-invokes. |
| `claude-works-completed/<slug>/` already exists at archive time | `BLOCKED: archive destination exists at <path> — manual cleanup required` (pre-checked in step 4 before `git mv`) |

## Out of Scope

- Rebase before merge — let glab/gh squash-merge handle it, or invoke `/qqq:rebase-conflict-resolve` separately.
- Worktree removal post-merge — `claude rm <id>` (the user's call).
- Validating `phase2-review-state.json` review fingerprint — D1− trusts the PR reviewer, not this skill.
- Multi-stage feature-branch → dev-branch → main pipelines — the old `merge-protocol.sh` flow is intentionally dropped.

## Notes

- The skill is intentionally narrow. Anything more sophisticated belongs in a follow-up that the user explicitly asks for.
- Description rendering is the only "smart" step; everything else is a one-line wrapper around `git` or `glab` / `gh`.
- Manual verification (one real GitLab/GitHub merge against a throwaway branch) is required before this skill is considered shipped — see `MIGRATION_PLAN.md §7 step 9`.
