# Codex Failure Stub — Shared Format

When the Codex primary attempt fails (any of: non-zero exit, missing/empty `$out_file`, JSON parse error, schema-validation error), the calling skill must persist a failure stub before deciding whether to fall back to Claude.

## When to use

The skill writes this stub to its canonical artifact path (e.g., `phase3-codex-review-{k}.md`, `phase2-g1-explorer-{k}.md`, `phase1-tech-spec-sanity.md`, `rebase-conflict-codex-{k}.md`). The stub records the failure for audit before the fallback path overwrites the artifact with the final result.

## Stub format

The header is per-skill — match the success-case header structure of that skill's artifact (titles, field names, etc.). The body section uses the canonical failure block:

```markdown
## Codex Failure (primary path)

- Engine: Codex
- Mode: primary
- Outcome: FAILURE — {falling back to Claude | REJECT, fallback not allowed}
- Failure category: {missing_cli | auth | quota | model_unavailable | unsupported_config | transport | timeout | schema | unknown}
- Fallback allowed: {yes | no}
- Fallback reason: {one-line rationale referencing the category, e.g., "auth → infra-class, fallback allowed"}
- Codex version: {output of `codex --version` captured at failure time; "unknown" if the version probe also failed}
- Effective model: {value of `-m` in the failed command}
- Effective reasoning effort: {value of `model_reasoning_effort` in the failed command}
- Command: {full command with <session_dir>, <plugin_root>, etc. resolved to absolute paths}
- Exit code: {n}
- Primary error: {first non-noise stderr line, or "unknown" if isolation failed}
- Suppressed warnings: {known-noise lines elided here; raw text remains in the stderr tail below}
- Stderr (raw tail, first ~40 lines):
  {...}
- Stdout (trimmed, first ~20 lines):
  {...}
- Output file (`$out_file`): {empty | non-empty, raw contents below}
```

`Codex version`, `Effective model`, and `Effective reasoning effort` are captured at failure time only — they do not appear on success-case headers. Probe the version with a separate `codex --version` call when filling the stub; if that probe also fails, write `unknown`. `Effective model` / `Effective reasoning effort` are echoed from the values the skill already passed to `codex exec`, not from a new probe.

After writing the stub, the skill consults `fallback-policy.md` next to this file to decide whether the failure category permits a Claude fallback.

## Failure Categories

Categorize the failure by scanning the captured stderr/stdout against the patterns below; the first matching category wins, otherwise `unknown`. Categorization happens once, before the fallback-policy lookup.

| Category | Pattern hints (case-insensitive) | Class |
|---|---|---|
| `missing_cli` | `which codex` returned non-zero before `codex exec` was attempted | infra |
| `auth` | `unauthorized`, `forbidden`, `login`, `credential`, `not authenticated` | infra |
| `quota` | `rate limit`, `quota`, `429`, `too many requests`, `usage limit`, `billing`, `capacity` | infra |
| `model_unavailable` | `model unavailable`, `model not found`, `service unavailable`, `overloaded`, `503` | infra |
| `transport` | `connection reset`, `broken pipe`, `transport`, `dns`, `network timed out` | infra |
| `timeout` | wall-clock exceeded the skill-local budget before any other category matched | infra |
| `unsupported_config` | `unsupported`, `invalid config`, `unknown key`, `invalid value for` (e.g. `Unsupported service_tier:`) | bug |
| `schema` | `--output-schema` JSON parse error, schema validation failure, missing required field | bug |
| `unknown` | none of the above matched | uncategorized |

The category → fallback-allowed mapping is owned by `fallback-policy.md`. Do not duplicate it here.

## Noise patterns (suppress, do not surface as `Primary error`)

These stderr lines are known noise. The categorizer ignores them when isolating `Primary error`, but they still appear in the raw stderr tail for audit.

- `WARNING: proceeding, even though we could not update PATH`
- (extend as new noise patterns are observed in practice)

## After a successful fallback

The Claude-engine fallback writes the final artifact to the same path, replacing the failure stub. Do not preserve both — the fallback artifact is the canonical record. The stub itself is transient state used only for audit during the fallback decision.

## Hard rules

- Do not retry the Codex primary inline. The stub is single-shot; one fallback follows.
- Do not bypass the stub on the assumption that the failure is "obviously infrastructure". Always write the stub first; let the fallback step decide.
- Do not include the prompt file content in the stub (it lives in `$prompt_file` already, and may be very long). Reference its path instead.
- Always emit a `Failure category` value. If no pattern matches, use `unknown` — never leave the field blank or invent a new category inline. New categories must be added to this file first.
