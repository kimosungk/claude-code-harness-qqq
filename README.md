# qqq — Three-Phase Development Harness for Claude Code

A Claude Code plugin that turns vague requests into reviewed, verified implementations. Each phase has a clear deliverable, a Socratic loop with the user, and a self-managed reviewer pass before moving forward.

```
Phase 1 → Phase 2 → Phase 3
clarify    plan       implement
```

Phase 1 produces an approved spec (and optional UI outline / NLTP). Phase 2 produces a reviewed code plan. Phase 3 executes the plan and reviews the diff. Each phase blocks on its own review loop, so nothing moves forward unreviewed.

## Install

### Option A — Test locally with `--plugin-dir`

Clone the repo and point Claude Code at it:

```bash
git clone https://github.com/kimosungk/claude-code-harness-qqq.git
claude --plugin-dir ./claude-code-harness-qqq
```

The plugin's skills are then available as `/qqq:<skill-name>` (for example `/qqq:clarify-requirement`).

### Option B — Persistent install via marketplace

Once a marketplace hosts this plugin, install with `/plugin install qqq@<marketplace>`. See [Claude Code plugin docs](https://code.claude.com/docs/en/plugins) for marketplace setup.

### Hooks companion pack (per-project)

The plugin ships hook scripts under `hooks/`, but they are **not** auto-registered into your project. Install them into a target project's `.claude/` so artifact protection, session logging, and stop guards take effect:

```bash
# from the project root you want qqq to guard:
/qqq:install
```

This skill copies the five hooks into `<project>/.claude/hooks/` and merges hook entries into `<project>/.claude/settings.json`. Re-run after plugin updates to pick up hook changes.

To validate an existing install:

```bash
bash scripts/validate-qqq-hooks.sh <project_root>
```

## Dependencies

| Dependency | Required for | Notes |
|---|---|---|
| `bash` 4+ | hooks, scripts | macOS default 3.2 not supported by `qqq-workflow.sh` |
| `jq` | hooks (JSON payload parsing) | required |
| `git` | all phase agents | required |
| `fzf` + `tmux` | `scripts/qqq-workflow.sh` | only if you use the fzf+tmux launcher |
| `codex` CLI | Codex-first review skills | optional — Claude fallback runs automatically if Codex is unavailable |
| `glab` | GitLab MR creation | only used by `qqq-workflow.sh` merge action |
| `playwright-cli` plugin | `ui-verifier` agent | **separate plugin**, install alongside qqq if you use `ui-verifier` |

## What's inside

13 agents under `agents/`, 14 skills under `skills/`, 5 hooks under `hooks/`, 5 scripts under `scripts/`, plus the fzf+tmux workflow tool.

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
| `qqq:code-implementer` / `qqq:code-implement` | Executes the plan, writes `phase3-implement-log.md`, drives reviewer loop |
| `qqq:code-implement-reviewer` / `qqq:code-implement-review` | Codex-first diff review with Claude fallback |

### Auxiliary

| Component | Purpose |
|---|---|
| `qqq:rebase-conflict-resolver` / `qqq:rebase-conflict-resolve` | Resolve in-progress git rebase conflicts (Codex-first, Claude fallback) |
| `qqq:ui-verifier` | Browser-based UI verification via `playwright-cli` (separate plugin). Project conventions persist via agent memory |
| `qqq:debug-frontend-pw` | Root-cause investigation in the browser via `playwright-cli` |
| `qqq:install` | Install hooks companion pack into a project's `.claude/` |

### Hooks (project-local, installed by `qqq:install`)

| Hook | Event | Purpose |
|---|---|---|
| `qqq-protect-files.sh` | `PreToolUse` (Edit/Write) | Blocks edits to `.qqq.lock`, frozen `claude-works-completed/`, and out-of-ownership artifacts |
| `qqq-log-event.sh` | `TaskCreated` / `TaskCompleted` | Append JSONL records to `.qqq/log.jsonl` |
| `qqq-context.sh` | `SessionStart` (compact) | Reminds Claude about frozen artifacts, ownership, next expected output |
| `qqq-stop-guard.sh` | `Stop` | Blocks phase agents from terminating before required artifacts exist |
| `qqq-notify.sh` | `Notification` | OS-native passive notifications (macOS / Linux / Windows) |

See `qqq-hooks-companion-pack.md` for the full hooks contract.

### `scripts/qqq-workflow.sh`

A self-contained fzf+tmux launcher for the phase workflow: pick a session, advance through phases, manage worktrees, run the GitLab merge flow. It is **independent of the agents/skills** — both can be used together or separately. Run `bash scripts/qqq-workflow.sh --help` for the action reference.

## Development

While iterating on the plugin, edit files in this repo and run `/reload-plugins` in Claude Code to pick up changes without restart. For larger restructuring, restart Claude Code so newly created skill/agent directories are watched.

```bash
# syntax-check shell hooks
bash -n hooks/qqq-protect-files.sh

# validate plugin manifest
jq empty .claude-plugin/plugin.json
```

## See also

- `IMPROVEMENTS.md` — backlog of deferred work
- `qqq-hooks-companion-pack.md` — hooks contract and JSONL schema
- [Claude Code plugin docs](https://code.claude.com/docs/en/plugins)
- [Subagent docs](https://code.claude.com/docs/en/sub-agents) — covers persistent agent memory used by `qqq:ui-verifier`
- [Skill docs](https://code.claude.com/docs/en/skills) — covers skill frontmatter and `${CLAUDE_SKILL_DIR}` substitution
