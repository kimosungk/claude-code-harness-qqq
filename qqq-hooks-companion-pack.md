# qqq Hooks Companion Pack

Project-local hook bundle for `qqq`. The core plugin still owns orchestration in `scripts/qqq-workflow.sh`; hook enforcement lives in each target project's `.claude/`.

## Entry Points

- Install: `scripts/install-qqq-hooks.sh [project_root]`
- Validate: `scripts/validate-qqq-hooks.sh [project_root]`
- Skill: `qqq:install`

If `project_root` is omitted, install/validate resolve it as:

1. `git rev-parse --show-toplevel`
2. current working directory

## Installed Files

- `.claude/settings.json`
- `.claude/hooks/qqq-protect-files.sh`
- `.claude/hooks/qqq-log-event.sh`
- `.claude/hooks/qqq-context.sh`
- `.claude/hooks/qqq-stop-guard.sh`
- `.claude/hooks/qqq-notify.sh`

## Settings Merge Contract

Installer-managed handlers are identified at the command level: any hook command targeting `.claude/hooks/qqq-*.sh` is qqq-owned.

Merge rules:

- Existing unrelated handlers are preserved.
- Mixed handlers are preserved: only qqq-owned commands are removed/replaced; user commands in the same handler stay intact.
- Required qqq handlers are re-added exactly once per event group.
- A timestamped backup of `.claude/settings.json` is created only when file content changes.
- If `settings.json` is invalid JSON, install fails before copying hook scripts.

Managed event groups:

- `PreToolUse` with matcher `Edit|Write` -> `.claude/hooks/qqq-protect-files.sh`
- `TaskCreated` -> `.claude/hooks/qqq-log-event.sh`
- `TaskCompleted` -> `.claude/hooks/qqq-log-event.sh`
- `Notification` with matcher `permission_prompt|idle_prompt|elicitation_dialog` -> `.claude/hooks/qqq-notify.sh`
- `SessionStart` with matcher `startup|resume|compact` -> `.claude/hooks/qqq-context.sh`
- `Stop` -> `.claude/hooks/qqq-stop-guard.sh`
- `SubagentStop` -> `.claude/hooks/qqq-stop-guard.sh`

## Hook Behavior

### `qqq-protect-files.sh`

- Blocks edits to `.qqq.lock` (runtime-owned by the workflow shell, never written via Claude)
- Blocks edits under `claude-works-completed/**`
- Enforces artifact ownership through a single table (`phase_artifact_owner`):
  - Phase agents own their phase artifacts (e.g. `code-planner` owns `phase2-code-plan.md`)
  - Launcher-owned artifacts (`phase0-issue.md`, `.qqq/session.json`) require an explicit `QQQ_AGENT=qqq-launcher` marker; main-session Claude is blocked by default. The workflow's shell-side writers do not need this marker because they bypass Claude's Write/Edit pipeline entirely.
  - `.qqq/session.json` is launcher-owned only when the path matches the canonical `*/.qqq/session.json` shape — incidental basename matches elsewhere are warned-only.
- Resolves active agent from hook payload first (`agent_type` / `subagent_type` / `task.*`), then falls back to `QQQ_AGENT`

### `qqq-log-event.sh`

- Logs `TaskCreated` / `TaskCompleted`
- Uses `QQQ_SESSION_DIR/.qqq/log.jsonl` when available
- Falls back to `<project_root>/.claude/qqq/log.jsonl` outside a qqq session
- Uses the same top-level record shape as workflow logging

Shared JSONL shape:

```json
{
  "schema_version": "1",
  "ts": "2026-04-23T13:46:18+09:00",
  "source": "hook|workflow",
  "event": "task_created|task_completed|agent_launch|worktree_create|worktree_remove|worktree_merge|merge_resume_push",
  "result": "started|completed|ok|error|blocked",
  "agent_type": "code-planner",
  "session_dir": "/abs/path/to/session",
  "cwd": "/abs/path/to/cwd",
  "details": {}
}
```

### `qqq-context.sh`

- Runs on `SessionStart` matcher `startup|resume|compact`
- Prints a short reminder about frozen artifacts, ownership, and the next expected artifact
- Early-exits when neither `$QQQ_SESSION_DIR` nor a session-shaped cwd is detected, so it is safe to widen beyond `compact`

### `qqq-stop-guard.sh`

- Allows immediately when `stop_hook_active=true`
- Uses payload `agent_type` before env fallback
- Runs on both `Stop` (top-level agent) and `SubagentStop` (Task-spawned reviewers)
- Phase agents (Stop):
  - `req-clarifier` requires `phase1-spec.md`
  - `tech-interviewer` requires `phase1-tech-spec.md`
  - `nltp-interviewer` requires `phase1-nltp.md` + at least one `phase1-nltp-review-*.md`
  - `code-planner` requires `phase2-code-plan.md` + `phase2-review-log.md`
  - `code-implementer` requires `phase3-implement-log.md` + at least one `phase3-*-review-*.md`
- Reviewer subagents (SubagentStop, defense-in-depth — round-number matching is wildcard, false negatives possible):
  - `nltp-reviewer` requires at least one `phase1-nltp-review-*.md`
  - `code-plan-review-explorer` requires `phase2-g1-explorer-*.md`
  - `code-plan-review-architect` requires `phase2-g2-architect-*.md`
  - `code-plan-review-critic` requires `phase2-g3-critic-*.md`
  - `code-implement-reviewer` requires `phase3-codex-review-*.md` or `phase3-claude-review-*.md`

### `qqq-notify.sh`

- macOS: `terminal-notifier`, else `osascript`
- Linux: `notify-send`
- Windows: `powershell.exe` with `BurntToast` toast when available
- If no passive notifier is available, it no-ops with a debug stderr message

## Workflow Integration

`scripts/qqq-workflow.sh` exports:

- `QQQ_AGENT`
- `QQQ_SESSION_DIR`
- `QQQ_PHASE`
- `QQQ_DEV_BRANCH`

It also appends workflow-side records to the same `.qqq/log.jsonl` stream for:

- agent launch
- human review launch
- worktree create / remove / merge
- merge resume push

## Validation Guarantees

`validate-qqq-hooks.sh` checks:

- `.claude/settings.json` exists and is valid JSON
- required hook scripts exist and are executable
- required qqq hook commands exist for all managed event groups
- qqq-owned commands are not duplicated

## Non-Goals

- No install into `~/.claude/settings.json`
- No uninstall command in v1
- No dedicated Claude `WorktreeCreate` / `WorktreeRemove` hooks; worktree lifecycle is logged by `qqq-workflow.sh`
