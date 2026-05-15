# qqq — Three-Phase Development Harness for Claude Code

A Claude Code plugin that turns vague requests into reviewed, verified implementations. Each phase has a clear deliverable, a Socratic loop with the user, and a self-managed reviewer pass before moving forward.

```
[Phase 0] → Phase 1 → Phase 2 → Phase 3
register     clarify    plan       implement
issue
(optional)
```

Phase 0 (optional) registers a GitLab issue as `phase0-issue.md` so Phase 1 starts with shared context. Phase 1 produces an approved spec (and optional UI outline / NLTP). Phase 2 produces a reviewed code plan. Phase 3 executes the plan and reviews the diff. Each phase is dispatched as a fresh Claude Code background session via the `scripts/qqq` CLI; phase artifacts accumulate in `claude-works/<date_slug>/` and are read by the next phase.

> **v3.0 migration note.** This version migrated the harness onto Claude Code v2.1.139+ standard infrastructure (`claude --bg / --worktree`, agent view, `~/.claude/jobs/`). The old fzf+tmux launcher (`scripts/qqq-workflow.sh`) and most of `scripts/lib/` were replaced by a single ~950-line `scripts/qqq` CLI + 2 hooks. See `MIGRATION_PLAN.md` for the design rationale.

## Install

### Option A — Test locally with `--plugin-dir`

```bash
git clone https://github.com/kimosungk/claude-code-harness-qqq.git
claude --plugin-dir ./claude-code-harness-qqq
```

Skills are then available as `/qqq:<skill-name>` (e.g. `/qqq:clarify-requirement`).

### Option B — Persistent install via marketplace

Once a marketplace hosts this plugin, install with `/plugin install qqq@<marketplace>`. See [Claude Code plugin docs](https://code.claude.com/docs/en/plugins) for marketplace setup.

### CLI shim

Add a shell alias so `qqq` resolves to the plugin's CLI:

```bash
alias qqq="$HOME/.claude/plugins/local/hskim-plugins/plugins/qqq/scripts/qqq"
# or, when testing locally:
alias qqq="/abs/path/to/claude-code-harness-qqq/scripts/qqq"
```

### Hooks companion pack (per-project)

The plugin ships hook scripts under `hooks/`, but they are **not** auto-registered into your project. Install them into a target project's `.claude/`:

```bash
# from the project root you want qqq to guard:
/qqq:install
```

This copies the two hooks (`qqq-protect-files.sh`, `qqq-context.sh`) into `<project>/.claude/hooks/` and merges hook entries into `<project>/.claude/settings.json`. Re-run after plugin updates.

To validate an existing install:

```bash
bash scripts/validate-qqq-hooks.sh <project_root>
```

## Dependencies

| Dependency | Required for | Notes |
|---|---|---|
| Claude Code **2.1.139+** | CLI + skills | hard-gated by `scripts/qqq` startup check; uses `claude --bg`, `claude attach`, `claude rm`, `--append-system-prompt-file` |
| `bash` 4+ | `scripts/qqq`, hooks | macOS default 3.2 is not supported |
| `fzf` | `scripts/qqq` TUI + picker | required |
| `jq` | CLI + hooks (JSON parsing) | required |
| `git` | all phase agents | required |
| `sha256sum` or `shasum -a 256` | Phase 2→3 review fingerprint | required |
| `glab` | `qqq new --issue N`, `/qqq:merge-mr` (GitLab) | optional |
| `gh` | `/qqq:merge-mr` (GitHub) | optional |
| `codex` CLI | Codex-first review skills | optional — Claude fallback runs automatically if Codex is unavailable |
| `playwright-cli` plugin | `ui-verifier` agent | **separate plugin**, install alongside qqq |

## `scripts/qqq` — CLI + TUI

The entry point. Run `qqq --help` for the command list.

| Command | What it does |
|---|---|
| `qqq` | TUI entry (fzf menu) |
| `qqq new <slug>` | Start a blank session in a new worktree (no issue) |
| `qqq new <slug> --issue N` | Fetch GitLab issue → write `phase0-issue.md` inside worktree → start Phase 1 |
| `qqq clarify` | Dispatch `/qqq:clarify-requirement` as a new bg session |
| `qqq ui` | Dispatch `/qqq:ui-outline` (Optional) |
| `qqq nltp` | Dispatch `/qqq:interview-nltp` (Optional) |
| `qqq tech-spec` | Dispatch `/qqq:interview-tech` |
| `qqq plan` | Dispatch `/qqq:code-plan` |
| `qqq implement` | Dispatch `/qqq:code-implement` |
| `qqq attach <id>` | `claude attach <id>` |
| `qqq pick` | fzf → `claude attach` |
| `qqq logs [<id>]` / `qqq stop [<id>]` / `qqq rm [<id>]` | Wrappers around `claude logs/stop/rm` (fzf if no id) |
| `qqq merge-mr` | Run `/qqq:merge-mr` (push + MR/PR + merge — thin wrapper, no validation) |
| `qqq verify` | Smoke tests (G1·G2·G4·G5·G6; G3 manual) |

### Phase-transition contract (F1=b)

Every phase command dispatches a **new background session**. There is no `--resume` for phase transitions. The next-phase skill reads previous-phase artifacts from disk (`phase{N-1}-*.md` in the worktree's `claude-works/<date_slug>/`).

### Race + isolation (CLI-9)

Before dispatching, `scripts/qqq`:

- Refuses if cwd is the main checkout (not a linked worktree)
- Refuses if any session at this worktree is in `working` / `idle` state
- Refuses if any session at this worktree is in `exited` state (abnormal — investigate first)
- Refuses if 2+ non-running sessions are at this worktree (confused state — `qqq pick` or `claude rm` first)

State is inferred from `~/.claude/jobs/<short>/state.json` — there is no qqq lock file.

## What's inside

13 phase agents under `agents/`, 14 skills under `skills/`, 2 hooks under `hooks/`, 4 scripts under `scripts/` (`qqq`, `install-qqq-hooks.sh`, `validate-qqq-hooks.sh`).

### Phase 0 — Register Issue (optional)

| Component | Purpose |
|---|---|
| `qqq new <slug> --issue N` (CLI) | Fetch a GitLab issue via `glab`, snapshot it as `phase0-issue.md` *inside the new worktree*, auto-commit it, then dispatch Phase 1 with `--append-system-prompt-file phase0-issue.md`. Owned by the CLI; `phase0-issue.md` is read-only to all phase agents. |

### Phase 1 — Clarify

| Agent / Skill | Purpose |
|---|---|
| `qqq:req-clarifier` / `qqq:clarify-requirement` | Socratic Q&A to draft `phase1-spec.md` |
| `qqq:ui-outliner` / `qqq:ui-outline` | (optional) Minimal HTML UI outline |
| `qqq:nltp-interviewer` / `qqq:interview-nltp` | (optional) Gherkin-style NLTP, gated by `qqq:nltp-reviewer` |
| `qqq:tech-interviewer` / `qqq:interview-tech` | Frozen technical spec (`phase1-tech-spec.md`) — locks tech stack, data model, constraints |

### Phase 2 — Plan

| Agent / Skill | Purpose |
|---|---|
| `qqq:code-planner` / `qqq:code-plan` | Drafts `phase2-code-plan.md`, then runs explorer → architect → critic review loop |
| `qqq:code-plan-review-explorer` | Gate 1 — verify plan facts, reuse, impact, pitfalls |
| `qqq:code-plan-review-architect` | Gate 2 — structure, layering, contracts, security |
| `qqq:code-plan-review-critic` | Gate 3 — premortem (failure modes, rollback, observability) |

### Phase 3 — Implement

| Agent / Skill | Purpose |
|---|---|
| `qqq:code-implementer` / `qqq:code-implement` | Executes the plan, writes `phase3-implement-log.md`, drives reviewer loop. **D1− gate**: requires `phase2-review-state.json` with `review_loop_completed: true`. |
| `qqq:code-implement-reviewer` / `qqq:code-implement-review` | Codex-first diff review with Claude fallback |

### Merge

| Skill | Purpose |
|---|---|
| `qqq:merge-mr` | Thin glab/gh wrapper. Detects host from origin URL, commits pending phase artifacts, archives `claude-works/<slug>/` → `claude-works-completed/<slug>/`, pushes, creates MR/PR with rendered description, merges. **No validation of review state** — branch protection / required approvals on the host is mandatory. |

### Auxiliary

| Component | Purpose |
|---|---|
| `qqq:rebase-conflict-resolver` / `qqq:rebase-conflict-resolve` | Resolve in-progress git rebase conflicts (Codex-first, Claude fallback) |
| `qqq:ui-verifier` | Browser-based UI verification via `playwright-cli`. Optional NLTP scenario contract drives the browser. |
| `qqq:debug-frontend-pw` | Root-cause investigation in the browser via `playwright-cli` |
| `qqq:install` | Install hooks companion pack into a project's `.claude/` |

### Hooks (project-local, installed by `qqq:install`)

| Hook | Event | Purpose |
|---|---|---|
| `qqq-protect-files.sh` | `PreToolUse` (Edit\|Write\|Bash) | Blocks Edit/Write/Bash commands targeting `claude-works-completed/` (frozen post-merge artifacts) |
| `qqq-context.sh` | `SessionStart` (startup\|resume\|compact) | Infers current phase from artifact presence and warns on uncommitted `phase{N}-*.md` |

> v3.0 dropped three earlier hooks. `qqq-log-event.sh` (JSONL session log) is replaced by `~/.claude/jobs/<id>/state.json` + `claude logs`. `qqq-stop-guard.sh` (phase-exit gate) is replaced by the inline D1− gate in `skills/code-implement/SKILL.md`. `qqq-notify.sh` (OS notifications) is replaced by Claude Code's built-in agent view.

## Quality model — D1−

qqq's phase gating is intentionally weak in v3.0. Only the Phase 2 → 3 transition has an automated gate (`review_loop_completed: true` check, inline in the implement skill). Other phases rely on model self-judgment, the PR reviewer, and operator discipline. This is an **operational contract**:

1. **PR review is the final QA**. The phase gates are *recommended flow*, not validation. Code correctness is the responsibility of the human reviewer on the MR/PR.
2. **Skipping phases is the operator's call**. `phase1-spec.md` is not required to enter Phase 2; the plan will just be worse.
3. **Modifying a plan after review bypasses Phase 3 re-review**. No fingerprint enforcement at dispatch time.

The trade-off is documented in `MIGRATION_PLAN.md §9.4`.

## Development

While iterating on the plugin, edit files in this repo and run `/reload-plugins` in Claude Code to pick up changes without restart. For larger restructuring (new skill/agent directories), restart Claude Code so the new directories are watched.

```bash
# syntax-check
bash -n scripts/qqq hooks/qqq-protect-files.sh hooks/qqq-context.sh

# validate plugin manifest
jq empty .claude-plugin/plugin.json

# cheap smoke test
./scripts/qqq verify --cheap-only

# live smoke test (~2-3 min, costs API tokens — uses a disposable bg session)
./scripts/qqq verify
```

## See also

- `MIGRATION_PLAN.md` — v3.0 design (CLI surface, F1=b, D1−, CLI-9, hook reduction)
- `HANDOFF.md` — running migration progress log
- `qqq-hooks-companion-pack.md` — hooks contract (v3.0 scope)
- `UPDATE_GUIDE.md` — single-source-of-truth update procedure
- [Claude Code plugin docs](https://code.claude.com/docs/en/plugins)
- [Subagent docs](https://code.claude.com/docs/en/sub-agents) — covers persistent agent memory used by `qqq:ui-verifier`
- [Skill docs](https://code.claude.com/docs/en/skills) — covers skill frontmatter and `${CLAUDE_SKILL_DIR}` substitution
