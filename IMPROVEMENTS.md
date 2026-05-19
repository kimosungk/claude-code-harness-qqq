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
- [x] Structured JSON log under `.qqq/log.jsonl` for post-hoc analysis via workflow + hook writers (v2.0.0+hooks pack)
- [x] Configurable `QQQ_DEV_BRANCH` surfaced in `qqq --help` (v2.0.0)
- [ ] Surface the `--merge-resume-push` flag in the action menu when a prior merge failed to push (currently CLI-only)

## 5. Documentation

- [x] Hooks companion pack reference doc (`qqq-hooks-companion-pack.md`) — *removed in v3.1 (plugin-level hooks)*
- [ ] End-to-end walkthrough video/screencast linked from qqq-orchestrator-guide.md
- [x] "Recovery cookbook" — covered by Scenario K in qqq-orchestrator-guide.md (v2.0.0)
- [x] Migration guide from v1.x leader-cwd workflow to v2.x — implicit via `worktree-create` auto-migrate; documented in Scenario H

## 6. Test suite — pre-existing failures discovered during PR2-tier review

These were exposed (not caused) by aligning `test-qqq-workflow-ui.sh` with the leader-mode bootstrap that became the default in commit e72e2ea. The leader-mode fix unblocked test execution, after which these surfaced. Untouched by PRs 1-5; tracked here so the workflow split (Item 4 in §4) does not get blamed for them.

- [x] `test_agent_window_preflight_non_duplicate_choices_and_ignores_non_agent_windows`: utility-window assertion (`${win_slug}:view-artifacts`) ends up inside `run_agent` captured output. Resolved silently — full UI run now passes the assertion (no FAIL line in the trace where it used to surface). Root cause was likely fixed incidentally by one of the lib splits in PRs 7-8 reordering the preflight output path; the assertion stayed valid throughout. Closed in PR11.
- [x] `mkdir: cannot create directory '/.git': Permission denied` emitted late in the same test run. Root cause: `test_rebase_conflict_preflight_uses_same_duplicate_rules` called `make_bootstrapped_session` (which yields a leader-mode session with no worktree) and then immediately required a worktree git-dir. `qqq_session_dir_worktree` returned empty, `git -C "" rev-parse --git-dir` resolved to the test runner's own `.git`, then `mkdir -p "/.git/rebase-merge"` hit perm denied. Fix: switch to `qqq_bootstrap_session_worktree` (matching the pattern in `test_worktree_merge_archives_bootstrapped_session`). Closed in PR11.

---

## Anti-scope (do not implement)

These have been considered and intentionally rejected to keep qqq lightweight:

- Commit-hygiene ledger / tick loop / auto-integrate orchestration (OMX team runtime patterns)
- Per-phase auto-commit hook — replaced by merge-time 1-shot commit (design decision #12 v2)
- 3-step cleanup dialog by default — replaced by 1-prompt `[Y/n/selective]` (design decision #13 v2)
