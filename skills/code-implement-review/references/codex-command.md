# Codex Command — Shared Reference (Source of Truth)

**This file is the source of truth** for the qqq codex invocation pattern AND for the model / effort / sandbox values used by every qqq codex-using skill — `code-implement-review`, the three `code-plan-review-*` gates, `interview-tech` sanity-check, `rebase-conflict-resolve`.

Each skill's own `codex-primary.md` (or `codex-sanity-check.md`) keeps the literal `codex exec` command block for executability, but its `-m` / `model_reasoning_effort` / `--sandbox` values are **mirrors of the table in §"Per-agent overrides" below**. The skill files MUST stay in sync with this table.

### Update protocol when changing a model, effort, or sandbox value

1. Update the row in §"Per-agent overrides" below (this is the canonical change).
2. Update the matching `-m` / `-c 'model_reasoning_effort=…'` / `--sandbox` value in the skill's own `codex-primary.md` (or `codex-sanity-check.md`).
3. Update the skill-specific rationale prose under that command if the reasoning behind the choice changed.

Drift between this table and a skill file is a bug. If you find drift, treat **this table** as authoritative and fix the skill file.

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

The values in this table are **canonical**. The matching skill-side `codex-*.md` files mirror them.

| Skill (path) | `<MODEL>` | `<EFFORT>` | `<SANDBOX>` |
|---|---|---|---|
| `code-implement-review/references/codex-primary.md` (Phase 3 review) | `gpt-5.5` | `xhigh` | `read-only` |
| `code-plan-review-explorer/references/codex-primary.md` (Phase 2 Gate 1) | `gpt-5.4` | `high` | `read-only` |
| `code-plan-review-architect/references/codex-primary.md` (Phase 2 Gate 2) | `gpt-5.5` | `xhigh` | `read-only` |
| `code-plan-review-critic/references/codex-primary.md` (Phase 2 Gate 3) | `gpt-5.5` | `high` | `read-only` |
| `interview-tech/references/codex-sanity-check.md` (Phase 1 sanity-check) | `gpt-5.4` | `medium` | `read-only` |
| `rebase-conflict-resolve/references/codex-primary.md` | `gpt-5.5` | `high` | `workspace-write` |

Selection logic (mnemonic — full per-skill rationale stays in the skill file):

- `gpt-5.5` for tasks that judge intent or merge safety (architect, critic, Phase 3 review, rebase). `gpt-5.4` for mechanical fact / consistency checking (explorer, sanity-check).
- `xhigh` for the two gates that are hardest to reverse downstream (architect locks structure, Phase 3 review is last before delivery). `high` for the other reasoning-judgment gates. `medium` for mechanical consistency checks.
- `read-only` everywhere review happens. `workspace-write` only when the skill must mutate the working tree (rebase resolution).

### Non-model overrides (paths)

- `<SCHEMA_FILE>` — absolute path under `<plugin_root>/skills/<skill>/references/<name>.schema.json`. All 6 codex-using skills now have their own schema.
- `<PROMPT_FILE>`, `<OUT_FILE>` — paths inside `<session_dir>` so the audit trail is preserved and the Write tool grant covers them.
- `<WORKDIR>` — `<session_dir>` for review skills; `<worktree>` for the rebase resolver.

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

Each skill's own codex-*.md carries **the rationale** for its choice of:

- `-m <MODEL>` — why `gpt-5.4` vs `gpt-5.5` for that scope
- `-c 'model_reasoning_effort="<EFFORT>"'` — why `medium` vs `high` vs `xhigh` for that scope
- `--sandbox <SANDBOX>` — why `read-only` vs `workspace-write`

Keep those rationales tight (1-3 lines each per flag). The **values themselves are mirrors of the §"Per-agent overrides" table above** — never change a value in only one place.

## Persist artifact failure stubs

For the failure-stub format (used when Codex exits non-0, the output file is missing/empty, JSON parsing fails, or schema validation fails), see `codex-failure-stub.md` next to this file.
