# qqq — Improvements Backlog

Technical debt and deferred work for the qqq plugin. Grouped by surface. Check items off as they land in a release.

Scope guardrail: qqq stays bash-only and lightweight. Anything that requires a runtime / daemon / persistent state beyond git refs and flat files belongs in a different tool.

---

## 1. GitLab MR integration

- [ ] `.gitlab/merge_request_templates/` multi-template picker via fzf (currently: single template auto-pick, multiple → fzf)
- [ ] `glab auth status` pattern matching for friendlier "run `glab auth login`" prompt
- [ ] Support `remote != origin` (single-origin assumption today — document when it bites)
- [ ] MR description re-use from prior MR on the same source branch (amend flow)

## 2. Worktree UX

- [ ] Cross-repo session picker (`QQQ_REPO_ROOTS` env or config file)
- [ ] Worktree health report: branch ahead/behind, rebase-in-progress, dirty summary in one view
- [ ] `qqq_list_worktrees` cache per menu loop (avoid repeated `git worktree list --porcelain` calls)
- [ ] bash 3.x fallback (currently hard-gated to 4+; macOS default stock bash is 3.2)
- [ ] Recovery confirmation consistency: align `worktree-remove` / picker discard / merge recovery prompts by risk level

## 3. Session picker

- [ ] Filter by status (active / merged / ghost) via fzf header toggle
- [ ] Colorized `[ghost]` / `[merged]` indicators when TTY supports
- [ ] Age indicator (hours/days since last mtime) next to slug

## 4. Orchestrator

- [ ] `--non-interactive` mode for scripted smoke tests
- [ ] Surface the `--merge-resume-push` flag in the action menu when a prior merge failed to push (currently CLI-only)

## 5. Documentation

- [x] Hooks companion pack reference doc (`qqq-hooks-companion-pack.md`) — *removed in v3.1 (plugin-level hooks)*

---

## Anti-scope (do not implement)

These have been considered and intentionally rejected to keep qqq lightweight:

- Commit-hygiene ledger / tick loop / auto-integrate orchestration (OMX team runtime patterns)
- Per-phase auto-commit hook — replaced by merge-time 1-shot commit (design decision #12 v2)
- 3-step cleanup dialog by default — replaced by 1-prompt `[Y/n/selective]` (design decision #13 v2)
