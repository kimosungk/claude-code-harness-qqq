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
- Outcome: FAILURE — falling back to Claude
- Command: {full command with <session_dir>, <plugin_root>, etc. resolved to absolute paths}
- Exit code: {n}
- Stderr (trimmed): {first ~40 lines}
- Stdout (trimmed): {first ~20 lines}
- Output file (`$out_file`): {empty | non-empty, raw contents below}
```

After writing the stub, the skill consults its own `claude-fallback.md` (or its SKILL.md fallback procedure) to decide whether the failure is infrastructure-class. The fallback-allowed reasons list lives in `fallback-policy.md` next to this file.

## After a successful fallback

The Claude-engine fallback writes the final artifact to the same path, replacing the failure stub. Do not preserve both — the fallback artifact is the canonical record. The stub itself is transient state used only for audit during the fallback decision.

## Hard rules

- Do not retry the Codex primary inline. The stub is single-shot; one fallback follows.
- Do not bypass the stub on the assumption that the failure is "obviously infrastructure". Always write the stub first; let the fallback step decide.
- Do not include the prompt file content in the stub (it lives in `$prompt_file` already, and may be very long). Reference its path instead.
