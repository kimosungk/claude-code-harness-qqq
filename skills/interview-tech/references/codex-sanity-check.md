# Codex Primary Path — Tech-Spec Sanity Check

Read this before running the sanity-check at the end of Phase 6 Step 1.

## Scope

Mechanical consistency check only:

- **spec_consistency** — a decision in `phase1-tech-spec.md` contradicts frozen `phase1-spec.md` (or `phase1-ui-outline.md` when present) without an Amendment Gate row in §7.
- **evidence_gap** — a locked decision in §3/§5/§6 is missing its evidence row or rationale.
- **nltp_coverage** — a scenario in `phase1-nltp.md` (when present) is not covered by the tech-spec's verification path.

This check is **advisory only**. It must never block freeze. The user remains the freeze authority.

This check must not:

- evaluate whether decisions are good, appropriate, modern, or aligned with industry trends
- propose alternative tech choices
- re-litigate decisions that already went through Forced L1 Review
- score architecture quality

## Inputs

- `Session dir` — absolute session directory containing the just-written `phase1-tech-spec.md`
- `phase1-spec.md` — frozen reference (always present)
- `phase1-tech-spec.md` — sanity-check target (just written by Phase 6 Step 1, still `Status: Draft`)
- `phase1-ui-outline.md` — frozen reference (when present)
- `phase1-nltp.md` — frozen reference (when present)

## Preflight

1. `which codex`
2. Confirm `phase1-tech-spec.md` exists in the session dir and is the just-written draft.
3. Read each input file fully (they are typically <50 KB each).

## Output Schema

The result shape is contractually pinned by `references/sanity-check.schema.json` (next to this file). Codex must return JSON conforming to that schema — `outcome` and a `findings` array.

When the model is genuinely uncertain whether a finding is mechanical or judgmental, it must omit the finding rather than guess. False positives erode trust faster than missed-but-fixable consistency issues.

## Prompt Template

Write this body to `<session_dir>/phase1-tech-spec-sanity-prompt.md`. Do not pass it as an argv positional — argv transport is fragile for multi-KB prompts (ARG_MAX, shell quoting, embedded `$()`/backticks in cited content) and Codex's documented stdin behavior makes it unsafe to mix argv prompt with an open stdin.

```text
You are a mechanical consistency checker for a frozen technical specification draft. You are NOT a tech reviewer. You do not evaluate whether decisions are good. You only verify internal consistency. Return JSON conforming to the supplied schema.

## Allowed finding categories
- spec_consistency: tech-spec decision contradicts frozen phase1-spec.md (or phase1-ui-outline.md when present), and there is no matching Amendment Gate row in §7 of phase1-tech-spec.md.
- evidence_gap: a locked decision in §3, §5, or §6 of phase1-tech-spec.md is missing its evidence row or rationale.
- nltp_coverage: when phase1-nltp.md is present, a scenario in that file is not covered by phase1-tech-spec.md's verification path.

## Forbidden finding categories
- "this stack would be better"
- "this pattern is unusual"
- "you should consider X instead"
- any subjective evaluation of decision quality

If a candidate finding requires subjective judgment to defend, OMIT it.

## Inputs

1. Frozen requirement spec:
<paste phase1-spec.md>

2. Frozen UI outline (when present):
<paste phase1-ui-outline.md or "N/A — not present">

3. Frozen NLTP (when present):
<paste phase1-nltp.md or "N/A — not present">

4. Tech-spec draft to sanity-check:
<paste phase1-tech-spec.md>

## Output rules
- Output the JSON object only. No prose preamble. No code fence around the JSON.
- Each finding's tech_spec_location must cite a section/row of phase1-tech-spec.md (e.g., "§3 row 2", "§5 — Database", "§7").
- Each finding text is one mechanical line, not a paragraph.
- severity is "info" for noteworthy consistency observations, "warn" for likely silent spec violations or substantive evidence gaps. There is no "block" severity — this check never blocks freeze.
- Set outcome to "clean" with empty findings when nothing material is found. Set outcome to "findings_present" only when findings is non-empty.
- When in doubt about whether a finding is mechanical or judgmental, omit it.
```

## Command

> **Mirror note.** The `-m`, `model_reasoning_effort`, and `--sandbox` values in this block are mirrored from the per-agent overrides table in `skills/code-implement-review/references/codex-command.md` — that table is the canonical source of truth. Update both this file and that table together on change.

```bash
prompt_file="<session_dir>/phase1-tech-spec-sanity-prompt.md"
out_file="<session_dir>/phase1-tech-spec-sanity-output.json"
schema_file="<plugin_root>/skills/interview-tech/references/sanity-check.schema.json"

# Write the prompt body (template above, with sections filled in) to $prompt_file
# using the Write tool. Do not use mktemp — it is not in the tool allowlist.

codex exec \
  -m gpt-5.4 \
  -c 'model_reasoning_effort="medium"' \
  --disable fast_mode \
  --sandbox read-only \
  --color never \
  --ephemeral \
  --output-schema "$schema_file" \
  --output-last-message "$out_file" \
  -C "<session_dir>" \
  - < "$prompt_file"
```

Per-skill flag rationale (intentionally lighter than Phase 2/3 reviewers):

- `-m gpt-5.4` — sanity-check is mechanical consistency only (3 narrow categories enforced by schema). The full `gpt-5.5` model is overkill for this scope; `gpt-5.4` covers it at a fraction of the quota.
- `-c 'model_reasoning_effort="medium"'` — same rationale. Mechanical checks do not benefit from `high` reasoning depth, and `medium` keeps the run well under the per-call quota budget. Do not push below `medium` — `low` and `minimal` start to skip cross-section consistency checks that this gate exists to catch.
- `--sandbox read-only` — sanity-check never writes.

If quota pressure tightens further, `gpt-5.4-mini` is a documented fallback choice (see `marketplaces/openai-codex/.../codex-rescue.md`); switch by editing the `-m` flag here.

For shared rationale (fast_mode, color, ephemeral, output-schema semantics, output-last-message, -C, stdin form), the canonical pattern, plugin_root resolution, and the stdin-hang background — see `code-implement-review/references/codex-command.md`.

## Persist

Always write `<session_dir>/phase1-tech-spec-sanity.md` (no round suffix — overwrite on re-run). The artifact is the human-readable summary; the raw JSON stays in `$out_file` for audit.

On success (Codex exit 0 and `$out_file` is valid JSON conforming to the schema):

```markdown
# Tech-Spec Sanity Check

- Engine: Codex (gpt-5.4, model_reasoning_effort=medium)
- Mode: primary
- Outcome: {clean | findings_present}
- Generated: {YYYY-MM-DD HH:MM}
- Advisory only — does not block freeze.

## Findings
- [{severity}] {category} · {tech_spec_location} — {finding}

(Repeat per finding. Render `_None._` when outcome is clean.)
```

On failure (non-zero exit, missing/empty `$out_file`, JSON parse error, or schema violation): treat as Codex infrastructure failure and consult `claude-fallback.md` next to this file for the inline-LLM fallback. The fallback-allowed reasons list lives in `code-implement-review/references/fallback-policy.md`; the same list applies here.

When persisting a Codex failure stub before fallback, write the artifact with header `# Tech-Spec Sanity Check — Codex Failure` and the canonical failure body documented in `code-implement-review/references/codex-failure-stub.md`. The Claude fallback then writes the final advisory artifact at the same path, replacing the failure stub.
