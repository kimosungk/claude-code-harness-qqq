# Codex Command — Shared Reference

Single source of truth for the qqq codex invocation pattern, per-flag rationale (the flags that do **not** vary per skill), plugin_root resolution, and the stdin-hang background. Read this from any qqq codex-using skill — `code-implement-review`, the three `code-plan-review-*` gates, `interview-tech` sanity-check, `rebase-conflict-resolve`.

Each skill's own `codex-primary.md` (or `codex-sanity-check.md`) keeps the literal command block and 1-3 lines of skill-specific rationale for the parts that vary (model, effort, sandbox). For everything else, point at this file.

## Canonical Pattern

The qqq codex invocation always has this shape (per-agent overrides marked `<...>`):

```bash
codex exec \
  -m <MODEL> \
  -c 'model_reasoning_effort="<EFFORT>"' \
  --disable fast_mode \
  --sandbox <SANDBOX> \
  --color never \
  --ephemeral \
  --output-schema "<SCHEMA_FILE>" \
  --output-last-message "<OUT_FILE>" \
  -C "<WORKDIR>" \
  - < "<PROMPT_FILE>"
```

All 6 qqq codex-using skills produce structured JSON output via `--output-schema`. Each skill owns its own schema next to its codex-*.md (e.g., `verdict.schema.json` for the 5 review/sanity skills, `resolution.schema.json` for the rebase resolver).

## Per-agent overrides

Each skill's own codex-*.md fixes its values for these positions:

- `<MODEL>` — `gpt-5.5` for Phase 2 architect, Phase 2 critic, Phase 3 implement review, and rebase resolver; `gpt-5.4` for Phase 2 explorer (Gate 1) and the Phase 1 sanity-check (lighter scope).
- `<EFFORT>` — `xhigh` for Phase 2 architect and Phase 3 implement review; `high` for Phase 2 explorer + critic and rebase resolver; `medium` for the Phase 1 sanity-check.
- `<SANDBOX>` — `read-only` for all read-only reviewers; `workspace-write` for `rebase-conflict-resolve` only.
- `<SCHEMA_FILE>` — absolute path under `<plugin_root>/skills/<skill>/references/<name>.schema.json`. All 6 codex-using skills now have their own schema.
- `<PROMPT_FILE>`, `<OUT_FILE>` — paths inside `<session_dir>` so the audit trail is preserved and the Write tool grant covers them.
- `<WORKDIR>` — `<session_dir>` for review skills; `<worktree>` for the rebase resolver.

If you change one of these values for a skill, edit only that skill's own codex-*.md. Do not edit this shared file.

## Plugin Root Resolution

Resolve `<plugin_root>` from `${CLAUDE_PLUGIN_ROOT}` when set. Otherwise derive from the running skill's path — the first ancestor directory that contains `.claude-plugin/`.

The schema file must already exist on disk before the codex call. Never inline schemas into the command line.

## Why `- < "<PROMPT_FILE>"` (stdin form)

`codex exec --help` documents that when both an argv prompt and an inherited stdin are present, Codex appends stdin as a `<stdin>` block. Claude Code's Bash tool inherits stdin as a non-TTY pipe that does not EOF, so Codex hangs forever waiting for the `<stdin>` block. This was responsible for ~9 of the early Claude-fallback rounds before the fix landed.

The fix is to:

1. Make stdin the only prompt channel (use `-` as the positional)
2. Redirect stdin from a real file (`< $PROMPT_FILE`) so the file's EOF closes stdin cleanly

Argv-as-prompt is also fragile for multi-KB prompts (ARG_MAX, shell quoting, embedded `$()` / backticks in cited code). Using a session-dir prompt file solves both problems with one form.

## Shared Flag Rationale (rarely-changing flags)

These flags are identical across all qqq codex calls. Per-skill files should not duplicate this rationale.

- `-c 'model_reasoning_effort="<EFFORT>"'` — verified config key. The bare `reasoning_effort` form is silently ignored and the run falls back to the global default (typically `xhigh`). Always set this explicitly.
- `--disable fast_mode` — equivalent to `-c 'features.fast_mode=false'` per `codex exec --help`. The user has globally disabled this via `codex features disable fast_mode`; the per-call form is kept for visibility and to survive any future config reset. Independent of model and effort — review quality is unaffected; only queue/latency tier changes.
- `--color never` — strip ANSI from stdout and logs. Parsers and artifacts must not see escape codes.
- `--ephemeral` — do not persist Codex session files to `$CODEX_HOME`. Each call is independent; resume across rounds is not used today.
- `--output-schema "$schema_file"` (when present) — pin the JSON shape so the persist step can validate before treating the result as authoritative. Codex's structured outputs guarantee schema conformance at the model layer; the persist step must still validate to fail-closed on rare edge cases.
- `--output-last-message "$out_file"` — capture the final agent message in a stable file. Read this file for the verdict, not the streaming stdout (which contains banners, reasoning summaries, and token-use lines).
- `-C "<workdir>"` — sets Codex's workdir explicitly. `--cd` / `-C` is a documented flag (do not assume it does not exist; it does).
- `- < "$prompt_file"` — see the stdin section above.

## Per-agent flag rationale lives in the per-skill file

Each skill's own codex-*.md explains its choice of:

- `-m <MODEL>` — why `gpt-5.4` vs `gpt-5.5` for that scope
- `-c 'model_reasoning_effort="<EFFORT>"'` — why `medium` vs `high` vs `xhigh` for that scope
- `--sandbox <SANDBOX>` — why `read-only` vs `workspace-write`

Keep those rationales tight (1-3 lines each per flag).

## Persist artifact failure stubs

For the failure-stub format (used when Codex exits non-0, the output file is missing/empty, JSON parsing fails, or schema validation fails), see `codex-failure-stub.md` next to this file.
