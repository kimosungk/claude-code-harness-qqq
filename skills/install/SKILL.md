---
name: install
description: "qqq:install — Install the qqq hooks companion pack into a target project's .claude/settings.json and .claude/hooks, then validate the result."
argument-hint: "[project_root]"
disable-model-invocation: true
allowed-tools: Read, Bash
model: sonnet
effort: low
---

# Install qqq Hooks Companion Pack

Install the project-local qqq hooks bundle. This skill is the supported entrypoint for hook setup; do not directly edit hook scripts or user-global `~/.claude/settings.json`.

Reference: `qqq-hooks-companion-pack.md`

## Process

1. Resolve the target project root.
   - If `$ARGUMENTS` is a directory, use it.
   - Otherwise try `git rev-parse --show-toplevel`.
   - If that fails, use the current working directory.
2. Run the plugin installer:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/install-qqq-hooks.sh" "<project_root>"
   ```
3. Run validation immediately after:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../scripts/validate-qqq-hooks.sh" "<project_root>"
   ```
4. Report the target root, changed files, and whether validation passed.

## Hard Rules

- The install target is always project-local `.claude/`; never write to `~/.claude/`.
- Preserve unrelated existing hooks in `.claude/settings.json`.
- Preserve mixed handlers: only qqq-owned `.claude/hooks/qqq-*.sh` commands are replaced.
- If `jq` is missing, stop and surface the installer's dependency error verbatim.
- If `.claude/settings.json` is invalid JSON, stop before copying hook scripts.
- Do not invent extra install modes. v1 is idempotent install + validate only.
