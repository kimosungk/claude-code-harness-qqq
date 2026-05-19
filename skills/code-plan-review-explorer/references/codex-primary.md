# Codex Primary Path — Gate 1 (Explorer)

Read this before the first review attempt of the round.

## Inputs

The planner sends a structured contract via `Task`. Use these fields verbatim:

- `Plan` — absolute path to `phase2-code-plan.md`
- `Session dir` — absolute session directory
- `Round` — integer `{k}`
- `Artifact` — absolute path the gate detail file must be written to (typically `<session_dir>/phase2-g1-explorer-{k}.md`)
- `Mode` — `fresh` or `resume`
- `Plan fingerprint`, `Invalidated by`, `Change summary` — context
- `Handoff` — normally `none` for this gate

Required-read files (when present in the session dir):

- `phase2-code-plan.md`
- `phase1-tech-spec.md`
- `phase1-spec.md`
- `phase1-ui-outline.md`
- `phase1-nltp.md`

## Preflight

1. `which codex`
2. Read each required input file from the session dir.
3. From the plan, list every `file:line` reference, every reuse target, and every named symbol the plan claims exists.
4. Decide whether `Mode: resume` is usable. If the prior session id is empty or the plan fingerprint changed in a way that invalidates earlier facts, downgrade to `fresh` and record `mode: fresh` in the persisted artifact along with the reason.

## Output Schema

The verdict shape is contractually pinned by `references/verdict.schema.json` (next to this file). Codex must return JSON conforming to that schema — verdict, blocking_reasons, next_action, and a sections object containing the markdown bodies for each gate section. The persist step adds engine, mode, round, plan fingerprint, and invalidated-by metadata; do not ask Codex to produce those.

## Prompt Template

Write this body to a prompt file under the session dir (see Command for the exact path). Do not pass it as an argv positional — argv transport is fragile for multi-KB prompts (ARG_MAX, shell quoting, embedded `$()`/backticks in cited code) and Codex's documented stdin behavior makes it unsafe to mix argv prompt with an open stdin.

```text
You are Gate 1 (Explorer) of the Phase 2 review pipeline. Verify factual grounding only. Do not perform structure judgment, premortem, or architecture redesign. Return JSON conforming to the supplied schema.

## Round Context
- Round: {k}
- Mode: {fresh|resume}
- Plan fingerprint: {sha256:...}
- Invalidated by: {reason or "none"}
- Change summary:
{change summary}

## Inputs
1. Spec (frozen):
<paste phase1-spec.md>

2. Tech spec (frozen, locked decisions):
<paste phase1-tech-spec.md>

3. UI outline (when present):
<paste phase1-ui-outline.md or "N/A">

4. NLTP (when present):
<paste phase1-nltp.md or "N/A">

5. Plan under review:
<paste phase2-code-plan.md>

## Gate scope
- Verify every plan claim that asserts a file, symbol, or behavior exists. Cite `file:line`.
- Verify every reuse target the plan proposes; flag anything that does not exist or is misnamed.
- Map the impact caller surface for the touched modules.
- Surface known pitfalls visible in the repo (e.g., recurring bug patterns, prior incidents).
- When phase1-tech-spec.md is present, check the plan's library/API references match the locked tech choices (existence/reference only — strategy fit is Gate 2's concern).
- When phase1-nltp.md is present, check that the plan's verification path covers the NLTP scenarios.

## Verdict rules
- "OKAY" only when factual grounding is materially correct.
- "REJECT" when the plan relies on nonexistent files/symbols, misses critical impact surface, proposes unsupported reuse, or contradicts locked tech choices.
- blocking_reasons must be non-empty when verdict is REJECT, each one keyed to file:line or exact file path.

## Section rules
Each section value is a markdown string rendered verbatim under its header. Use bullet lists where useful. Anchor every claim to file:line.
- premise_check — verify existence and accuracy of plan claims.
- tech_spec_consistency — set to null when phase1-tech-spec.md is absent. Otherwise verify references to the locked decisions.
- reuse_candidates — assess each proposed reuse target.
- impact_caller_map — list affected callers/modules with file:line anchors.
- known_pitfalls — repo-level pitfalls relevant to this plan.
- nltp_coverage — set to null when phase1-nltp.md is absent. Otherwise list NLTP scenarios and the plan steps that cover them.
- evidence — concise list of the key file:line anchors used to form the verdict.

## Output rules
- Output the JSON object only. No prose preamble. No code fence around the JSON.
- Do not include engine, mode, round, plan_fingerprint, or invalidated_by — the persist step adds those.
```

## Command

> **Mirror note.** The `-m`, `model_reasoning_effort`, and `--sandbox` values in this block are mirrored from the per-agent overrides table in `skills/code-implement-review/references/codex-command.md` — that table is the canonical source of truth. Update both this file and that table together on change.

Pipe the prompt file via stdin and use the `-` positional to disable argv-prompt — this gives Codex a clean EOF and avoids the documented hang where Codex waits for a `<stdin>` block when both an argv prompt and an inherited (non-TTY, never-EOFing) stdin are present.

```bash
prompt_file="<session_dir>/phase2-g1-explorer-codex-prompt-{k}.md"
out_file="<session_dir>/phase2-g1-explorer-codex-output-{k}.md"
schema_file="<plugin_root>/skills/code-plan-review-explorer/references/verdict.schema.json"

# Write the prompt body (template above, with sections filled in) to $prompt_file
# using the Write tool. Do not use mktemp — it is not in the tool allowlist.

codex exec \
  -m gpt-5.4 \
  -c 'model_reasoning_effort="high"' \
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

- `-m gpt-5.4` — Gate 1 is fact-checking against repo state, not deep reasoning. `gpt-5.4` is the lighter sibling of `gpt-5.5` and adequate for premise verification, reuse target existence, and impact-caller mapping.
- `-c 'model_reasoning_effort="high"'` — Gate 1 needs `high` (not `medium`) because cross-checking plan claims against many cited file:line anchors benefits from broader attention; lower effort risks missing fabricated symbols.
- `--sandbox read-only` — Gate 1 never writes.

For shared rationale (fast_mode, color, ephemeral, output-schema semantics, output-last-message, -C, stdin form), the canonical pattern, plugin_root resolution, and the stdin-hang background — see `code-implement-review/references/codex-command.md`.

## Persist

Always write the gate detail artifact to the exact `Artifact` path the planner supplied — typically `<session_dir>/phase2-g1-explorer-{k}.md`.

On success (Codex exit 0 and `$out_file` is valid JSON conforming to the schema):

```markdown
# Phase 2 Gate Detail

- Gate: explorer
- Round: {k}
- Verdict: {verdict}
- Engine: Codex
- Mode: {fresh|resume — what this gate actually ran as}
- Plan Fingerprint: {sha256:...}
- Blocking Reasons: {bullets from blocking_reasons, or "none"}
- Invalidated By: {reason or "none"}
- Next Action: {next_action}

## Premise Check
{sections.premise_check}

## Tech Spec Consistency
{sections.tech_spec_consistency, or "_N/A — phase1-tech-spec.md not present_"}

## Reuse Candidates
{sections.reuse_candidates}

## Impact Caller Map
{sections.impact_caller_map}

## Known Pitfalls
{sections.known_pitfalls}

## NLTP Coverage
{sections.nltp_coverage, or "_N/A — phase1-nltp.md not present_"}

## Evidence
{sections.evidence}
```

On failure (non-zero exit, missing/empty `$out_file`, JSON parse error, or schema violation): treat as Codex infrastructure failure and consult `code-implement-review/references/fallback-policy.md` for the allowed-reasons list. When fallback is allowed, the parent SKILL.md tells you to perform the Claude-native review yourself. Either way, the final artifact at the `Artifact` path must record the engine that actually produced the gate output.

When persisting a Codex failure stub (before fallback), keep the standard Phase 2 Gate Detail header (with `Engine: Codex`, `Mode: primary`) and write the canonical failure body documented in `code-implement-review/references/codex-failure-stub.md`. The body fills in `Outcome`, `Failure category`, and `Fallback allowed` per the canonical format; the Phase 2 header must not duplicate or contradict those values. If `Fallback allowed = no` (e.g., `unsupported_config`, `schema`, `unknown`), do not invoke the Claude fallback — return `REJECT` with the stub as the canonical artifact.
