# Codex Primary Path

Read this before the first attempt.

## Inputs

- `$ARGUMENTS` accepts:
  - a path to `phase2-code-plan.md`
  - a path to the session directory
  - optional `worktree=/abs/path`
  - optional `dev_branch=name`
- Session dir:
  - if the path ends with `phase2-code-plan.md`, use its parent
  - otherwise treat the path as the session dir
- Worktree:
  - use `worktree=` when provided
  - otherwise derive with `git -C <session_dir> rev-parse --show-toplevel`

Context files when present:
- `<session_dir>/phase1-spec.md`
- `<session_dir>/phase2-code-plan.md`
- `<session_dir>/phase1-ui-outline.md`

## Preflight

1. Check `codex`:
   ```bash
   which codex
   ```
2. Verify the rebase is active:
   ```bash
   git -C "<worktree>" rev-parse --git-dir
   ```
   Then check `rebase-merge` / `rebase-apply`.
3. Capture conflict state:
   ```bash
   git -C "<worktree>" status --short
   git -C "<worktree>" diff --name-only --diff-filter=U
   ```
4. If there are no unmerged files, stop with `BLOCKED`.
5. Determine round `k` from `rebase-conflict-codex-*.md`, default `1`.

## Output Schema

The resolution shape is contractually pinned by `references/resolution.schema.json` (next to this file). Codex must return JSON conforming to that schema — status (RESOLVED | BLOCKED | FAILED), summary, resolved_files, remaining_conflicts, commands_run, tests_run, notes. The persist step adds engine, mode, model, round, and any other resolver metadata; do not ask Codex to produce those.

## Prompt Template

```text
You are inside a git worktree with an in-progress rebase conflict.

Goal: resolve the current rebase conflict safely and minimally, then continue the rebase if it is safe.

Context:
- Worktree: <abs worktree path>
- Session dir: <abs session dir>
- Target branch being rebased onto: origin/<dev_branch>
- Requirement spec: <path or "missing">
- Approved plan: <path or "missing">
- UI outline: <path or "missing">

Required workflow:
1. Inspect the current git state and identify all unmerged files.
2. Read the spec/plan/UI outline files if they exist.
3. Inspect conflicted files and stage versions as needed (`git show :1:path`, `:2:path`, `:3:path`).
4. Resolve conflicts with the smallest safe edit consistent with the spec/plan and existing repo patterns.
5. Stage resolved files with `git add`.
6. Run `git diff --check`.
7. Attempt `git rebase --continue`.
8. If another conflict appears, repeat until the rebase finishes or you are blocked.

Hard rules:
- Do not widen scope beyond resolving the active rebase.
- Do not edit phase documents.
- Do not push, create commits manually, or abort the rebase.
- Leave the repo in the most informative state possible if blocked.

Output rules:
- Return JSON conforming to the supplied schema. No prose preamble. No code fence around the JSON.
- status enum: RESOLVED | BLOCKED | FAILED.
- resolved_files is non-empty only when status == RESOLVED.
- remaining_conflicts is empty only when status == RESOLVED.
- commands_run lists every shell command you executed, one per array entry.
- tests_run is an array of {command, result} objects; result enum: pass | fail | skipped | n/a. Use [] when no tests ran.
- notes is an array of one-line strings; use [] when nothing notable.
- Do not include resolver engine, mode, round, or model — the persist step adds those.
```

## Command

Pipe the prompt file via stdin and use the `-` positional to disable argv-prompt — this gives Codex a clean EOF and avoids the documented hang where Codex waits for a `<stdin>` block when both an argv prompt and an inherited (non-TTY, never-EOFing) stdin are present. Set the worktree explicitly with `-C` rather than `cd`-ing the parent shell.

```bash
# Write these inside the session dir so they are part of the audit trail and
# stay inside the Write(./rebase-conflict-*.md) tool grant.
prompt_file="<session_dir>/rebase-conflict-codex-prompt-{k}.md"
out_file="<session_dir>/rebase-conflict-codex-output-{k}.json"
schema_file="<plugin_root>/skills/rebase-conflict-resolve/references/resolution.schema.json"

# Write the prompt body (template above, with sections filled in) to $prompt_file
# using the Write tool. Do not use mktemp — it is not in the tool allowlist.

codex exec \
  -m gpt-5.5 \
  -c 'model_reasoning_effort="high"' \
  -c 'service_tier="flex"' \
  --disable fast_mode \
  --sandbox workspace-write \
  --color never \
  --ephemeral \
  --output-schema "$schema_file" \
  --output-last-message "$out_file" \
  -C "<worktree>" \
  - < "$prompt_file"
```

Per-skill flag rationale:

- `-m gpt-5.5` — rebase resolution involves judgment about merge intent and minimal-edit safety; the heavier model is appropriate.
- `-c 'model_reasoning_effort="high"'` — `high` balances catch rate against per-call cost. Resolution errors are recoverable (the user can abort the rebase), so `xhigh` is not warranted.
- `--sandbox workspace-write` — the resolver writes resolved files inside the worktree. This is the only qqq codex skill that writes; all other codex calls are read-only.

For shared rationale (service_tier, fast_mode, color, ephemeral, output-schema semantics, output-last-message, -C, stdin form), the canonical pattern, plugin_root resolution, and the stdin-hang background — see `code-implement-review/references/codex-command.md`.

## Persist

Always write `<session_dir>/rebase-conflict-codex-{k}.md`. The artifact is markdown for humans; source-of-truth fields come from `$out_file` (the JSON Codex produced).

On success (Codex exit 0 and `$out_file` is valid JSON conforming to the schema):
1. Validate: parse `$out_file` as JSON. If parse or schema validation fails (Codex normally enforces this, but verify), treat as failure.
2. Render the artifact:

```markdown
# Rebase Conflict Resolution — Round {k}

- Resolver engine: Codex (gpt-5.5, model_reasoning_effort=high)
- Mode: primary
- Status: {status}
- Worktree: {worktree absolute path}

## Summary
{summary}

## Resolved files
- {path}                   (or `_None._` when empty)

## Remaining conflicts
- {path}                   (or `_None._` when empty)

## Commands run
- {command}                (or `_None._` when empty)

## Tests run
- {command} → {result}     (or `_None._` when empty)

## Notes
- {note}                   (or `_None._` when empty)
```

On failure (non-zero exit, missing/empty `$out_file`, JSON parse error, or schema violation): replace the success header with `# Rebase Conflict Resolution — Codex Failure`, keep `Round: {k}` and `Mode: primary`, and write the canonical failure body documented in `code-implement-review/references/codex-failure-stub.md`. Then consult `code-implement-review/references/fallback-policy.md` to decide whether Claude fallback is allowed.
