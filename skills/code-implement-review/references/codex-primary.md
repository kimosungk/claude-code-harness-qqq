# Codex Primary Path

Read this before the first review attempt.

## Inputs

Resolved by the SKILL.md "Input Contract" section before this file runs:

- `<plan_path>` — from the `Plan:` label (or the bare argument in legacy mode)
- `<session_dir>` — from the `Session dir:` label (or `dirname <plan_path>` in legacy mode)
- `<round_k>` — from the `Round:` label (or computed by scanning `phase3-*-review-*.md` in legacy mode)
- `<codex_artifact_path>` — from the `Codex artifact:` label (or `<session_dir>/phase3-codex-review-<round_k>.md` in legacy mode)

Context files:
  - `<session_dir>/phase1-spec.md`
  - `<session_dir>/phase2-code-plan.md` (== `<plan_path>`)

## Preflight

1. Check `codex`:
   ```bash
   which codex
   ```
2. Round `k` comes from the `Round:` label; only fall back to scanning `phase3-codex-review-*.md` and `phase3-claude-review-*.md` (default `1`) when running in legacy bare-path mode.
3. Gather review inputs:
   ```bash
   git diff --stat
   git diff
   ```
4. Optionally read 1-3 highly changed files if the diff alone is ambiguous.

## Output Schema

The verdict shape is contractually pinned by `references/verdict.schema.json` (next to this file). Codex must return JSON conforming to that schema — verdict, four review lanes, and an issues array. The persist step adds engine, mode, model, round, and any other reviewer metadata; do not ask Codex to produce those.

## Prompt Template

Write this body to a prompt file under the session dir (see Command for the exact path). Do not pass it as an argv positional — argv transport is fragile for multi-KB prompts (ARG_MAX, shell quoting, embedded `$()`/backticks in diffs) and Codex's documented stdin behavior makes it unsafe to mix argv prompt with an open stdin.

```text
You are reviewing an implementation diff. Return JSON conforming to the supplied schema.

## Inputs
1. Requirement spec (frozen):
<paste phase1-spec.md — or a focused summary if very long>

2. Approved implementation plan (frozen):
<paste phase2-code-plan.md>

3. Current working diff:
<paste git diff --stat + the full git diff or focused hunks>

## Review lanes
- Architecture — fits existing patterns, no unjustified new structures
- Correctness & Testability — matches plan intent, acceptance checks are real, edge cases handled
- Security — auth/session/secret/validation boundaries respected
- Maintainability — naming consistent, scope tight, no drive-by refactors

## Verdict rules
- verdict = "OKAY" only when all four lanes are Pass and no CRITICAL/HIGH issues remain.
- verdict = "REJECT" otherwise. issues must be non-empty when verdict is REJECT.

## Output rules
- Output the JSON object only. No prose preamble, no code fence around the JSON.
- Each lane reason is one line, anchored to the diff (e.g. mention file:line where it matters).
- Each issue.location is `file:line`, `file:line-line`, or a bare file path when line cannot be pinned.
- Do not suggest changes to the spec or the plan. Review the diff only.
```

## Command

Run from any cwd; pass `-C "<session_dir>"` to set Codex's workdir. Pipe the prompt file via stdin and use the `-` positional to disable argv-prompt — this gives Codex a clean EOF and avoids the documented hang where Codex waits for a `<stdin>` block when both an argv prompt and an inherited (non-TTY, never-EOFing) stdin are present.

```bash
# Write these inside the session dir so they are part of the audit trail and
# stay inside the Write(./phase3-*.md) tool grant.
prompt_file="<session_dir>/phase3-codex-prompt-{k}.md"
out_file="<session_dir>/phase3-codex-output-{k}.md"
schema_file="<plugin_root>/skills/code-implement-review/references/verdict.schema.json"

# Write the prompt body (template above, with sections filled in) to $prompt_file
# using the Write tool. Do not use mktemp — it is not in the tool allowlist.

codex exec \
  -m gpt-5.5 \
  -c 'model_reasoning_effort="xhigh"' \
  -c 'service_tier="flex"' \
  --disable fast_mode \
  --sandbox read-only \
  --color never \
  --ephemeral \
  --output-schema "$schema_file" \
  --output-last-message "$out_file" \
  -C "<session_dir>" \
  - < "$prompt_file"
```

Per-skill flag rationale:

- `-m gpt-5.5` — Phase 3 review judges output that is about to ship; the heavier model is justified by the cost of a missed defect cascading into production.
- `-c 'model_reasoning_effort="xhigh"'` — deepest reasoning tier. Phase 3 is the last gate before delivery, so per-call depth wins over per-call cost.
- `--sandbox read-only` — review never writes.

For shared rationale (service_tier, fast_mode, color, ephemeral, output-schema semantics, output-last-message, -C, stdin form), the canonical pattern, plugin_root resolution, and the stdin-hang background — see `codex-command.md` next to this file.

## Persist

Always write `<session_dir>/phase3-codex-review-{k}.md`. The file is markdown, not JSON — it is what humans read. Source-of-truth fields come from `$out_file` (the JSON Codex produced).

On success (Codex exit 0 and `$out_file` non-empty):
1. Validate: parse `$out_file` as JSON. If it does not parse or fails the schema (Codex normally enforces this, but verify), treat as failure (see below).
2. Render: write the artifact with this header followed by markdown sections derived from the JSON.

```markdown
# Phase 3 Implementation Review

- Reviewer engine: Codex (gpt-5.5, model_reasoning_effort=xhigh)
- Mode: primary
- Round: {k}
- Verdict: {verdict}

## Lanes
- Architecture: {lanes.architecture.status} — {lanes.architecture.reason}
- Correctness & Testability: {lanes.correctness_and_testability.status} — {lanes.correctness_and_testability.reason}
- Security: {lanes.security.status} — {lanes.security.reason}
- Maintainability: {lanes.maintainability.status} — {lanes.maintainability.reason}

## Issues
- [{severity}] `{location}` — {description}
  Fix: {fix}

(Repeat per issue. Render `_None._` when issues is empty.)
```

On failure (non-zero exit, missing/empty `$out_file`, JSON parse error, or schema violation): replace the success header above with `# Phase 3 Implementation Review — Codex Failure`, keep `Round: {k}` and `Mode: primary`, then write the canonical failure body documented in `codex-failure-stub.md` (next to this file). Consult `fallback-policy.md` to decide whether Claude fallback is allowed.
