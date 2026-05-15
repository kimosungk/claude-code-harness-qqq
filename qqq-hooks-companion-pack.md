# qqq Hooks Companion Pack (v3.0)

Project-local hook bundle for `qqq`. Orchestration lives in `scripts/qqq` (CLI + fzf TUI); hook enforcement is project-local under `.claude/`.

> **v3.0 scope reduction.** Three hooks were dropped — `qqq-log-event.sh` (replaced by `~/.claude/jobs/<id>/state.json` + `claude logs`), `qqq-stop-guard.sh` (replaced by inline D1− gate in `skills/code-implement/SKILL.md`), and `qqq-notify.sh` (replaced by Claude Code's agent view). Only two hooks remain.

## Entry Points

- Install: `scripts/install-qqq-hooks.sh [project_root]`
- Validate: `scripts/validate-qqq-hooks.sh [project_root]`
- Skill: `qqq:install`

If `project_root` is omitted, install/validate resolve it as:

1. `git rev-parse --show-toplevel`
2. current working directory

## Installed Files

- `.claude/settings.json` (merged, not replaced)
- `.claude/hooks/qqq-protect-files.sh`
- `.claude/hooks/qqq-context.sh`

## Settings Merge Contract

Installer-managed handlers are identified at the command level: any hook command targeting `.claude/hooks/qqq-*.sh` is qqq-owned.

Merge rules:

- Existing unrelated handlers are preserved.
- Mixed handlers are preserved: only qqq-owned commands are removed/replaced; user commands in the same handler stay intact.
- Required qqq handlers are re-added exactly once per event group.
- A timestamped backup of `.claude/settings.json` is created only when file content changes.
- If `settings.json` is invalid JSON, install fails before copying hook scripts.

Managed event groups (v3.0 — reduced from 7 to 2):

- `PreToolUse` with matcher `Edit|Write|Bash` → `.claude/hooks/qqq-protect-files.sh`
- `SessionStart` with matcher `startup|resume|compact` → `.claude/hooks/qqq-context.sh`

## Hook Behavior

### `qqq-protect-files.sh`

- Blocks Edit/Write/Bash commands targeting paths under `claude-works-completed/**` (frozen post-merge artifacts — Q2 scope).
- Matcher is `Edit|Write|Bash`. The Edit/Write arm enforces artifact protection at the tool layer; the Bash arm hard-blocks shell commands that touch the same paths.
- v3.0 dropped the artifact-ownership table from earlier versions. Phase ownership is enforced by skill design (which agent runs in which phase), not by hook.

### `qqq-context.sh`

- Runs on `SessionStart` matcher `startup|resume|compact`.
- Infers current phase from artifact presence in the session dir.
- Warns when `phase{N}-*.md` artifacts are uncommitted (the user is responsible for committing them before the next phase — D1− principle).
- Early-exits when no `claude-works/<date_slug>/` session dir is detected in cwd, so it is safe even outside a qqq session.

## CLI Integration

`scripts/qqq` does NOT export environment variables for hook consumption. The hooks operate purely from the session-dir convention (`claude-works/<date_slug>/`) and the artifact filesystem state. This is intentional — v3.0 dropped `QQQ_AGENT` / `QQQ_SESSION_DIR` env-coupling in favor of pure path inference.

## Validation Guarantees

`validate-qqq-hooks.sh` checks:

- `.claude/settings.json` exists and is valid JSON
- Required hook scripts exist and are executable
- Required qqq hook commands exist for the 2 managed event groups
- qqq-owned commands are not duplicated

## Non-Goals

- No install into `~/.claude/settings.json` (project-local scope only).
- No uninstall command.
- No dedicated worktree-lifecycle hooks — Claude Code's built-in `--worktree` + `claude rm` handle this.
- No JSONL session log — use `claude logs <id>` instead.
- No stop-time artifact guards — replaced by the inline D1− gate in `skills/code-implement/SKILL.md`.
