# Codex Primary Path — Gate 2 (Architect)

Read this before the first review attempt of the round.

## Inputs

The planner sends a structured contract via `Task`. Use these fields verbatim:

- `Plan` — absolute path to `phase2-code-plan.md`
- `Session dir` — absolute session directory
- `Round` — integer `{k}`
- `Artifact` — absolute path the gate detail file must be written to (typically `<session_dir>/phase2-g2-architect-{k}.md`)
- `Mode` — `fresh` or `resume`
- `Plan fingerprint`, `Invalidated by`, `Change summary` — context
- `Handoff` — compact explorer summary from Gate 1; treat as prior verified context, not a request to repeat the work

Required-read files (when present in the session dir):

- `phase2-code-plan.md`
- `phase1-tech-spec.md` (locked structural decisions: DI strategy, package boundaries, store scope)
- `phase1-spec.md`
- `phase1-ui-outline.md`
- plan-referenced repo files that matter to structure or contracts
- repo convention docs directly relevant to the plan, when they exist

## Preflight

1. `which codex`
2. Read each required input file from the session dir.
3. Decide whether `Mode: resume` is usable. If the prior session id is empty or the plan fingerprint changed in a way that invalidates earlier structural facts, downgrade to `fresh` and record the reason.

## Output Schema

The verdict shape is contractually pinned by `references/verdict.schema.json` (next to this file). Codex must return JSON conforming to that schema — verdict, blocking_reasons, next_action, and a sections object containing the markdown bodies for each gate section. The persist step adds engine, mode, round, plan fingerprint, and invalidated-by metadata; do not ask Codex to produce those.

## Prompt Template

Write this body to a prompt file under the session dir (see Command for the exact path). Do not pass it as an argv positional — argv transport is fragile for multi-KB prompts and Codex's documented stdin behavior makes it unsafe to mix argv prompt with an open stdin.

```text
You are Gate 2 (Architect) of the Phase 2 review pipeline. Evaluate the plan's structural fit and contract choices. Do not repeat Gate 1 fact validation. Do not perform premortem analysis. Return JSON conforming to the supplied schema.

## Round Context
- Round: {k}
- Mode: {fresh|resume}
- Plan fingerprint: {sha256:...}
- Invalidated by: {reason or "none"}
- Change summary:
{change summary}
- Handoff (Gate 1 explorer summary, treat as prior verified context):
{handoff}

## Inputs
1. Spec (frozen):
<paste phase1-spec.md>

2. Tech spec (frozen, locked decisions):
<paste phase1-tech-spec.md>

3. UI outline (when present):
<paste phase1-ui-outline.md or "N/A">

4. Plan under review:
<paste phase2-code-plan.md>

5. Repo convention docs that matter (when present):
<paste relevant docs or "N/A">

## Gate scope
- Structure, layer, and package fit — does the plan respect existing module boundaries?
- DI/store scope and reuse strategy — does it match the locked decisions in phase1-tech-spec.md?
- Contracts, interfaces, and public surface changes — are they minimal and consistent?
- Security boundary placement — auth/session/secret/validation handled at the right layer?
If a repo convention or policy file does not exist for one of these axes, mark that axis as N/A in the section body instead of inventing a rule.

## Verdict rules
- "OKAY" when the proposed structure fits existing patterns and no material contract/boundary risk remains.
- "REJECT" when the plan introduces unjustified new layers, crosses boundaries incorrectly, duplicates existing patterns, leaves contract/security boundaries underspecified, or contradicts locked structural decisions in phase1-tech-spec.md.
- blocking_reasons must be non-empty when verdict is REJECT, each one keyed to file:line or exact file path.

## Section rules
Each section value is a markdown string rendered verbatim under its header. Anchor every claim to file:line.
- structure_fit — module/layer/package fit assessment.
- reuse_and_boundaries — DI/store scope, reuse strategy, boundary judgments.
- contracts_and_security — interface/public-surface changes and security boundary placement.
- simulated_steps — a short walkthrough of the highest-risk step or two, not the entire plan.
- evidence — concise list of the key file:line anchors used to form the verdict.

## Output rules
- Output the JSON object only. No prose preamble. No code fence around the JSON.
- Do not include engine, mode, round, plan_fingerprint, or invalidated_by — the persist step adds those.
```

## Command

```bash
prompt_file="<session_dir>/phase2-g2-architect-codex-prompt-{k}.md"
out_file="<session_dir>/phase2-g2-architect-codex-output-{k}.md"
schema_file="<plugin_root>/skills/code-plan-review-architect/references/verdict.schema.json"

# Write the prompt body (template above, with sections filled in) to $prompt_file
# using the Write tool. Do not use mktemp — it is not in the tool allowlist.

codex exec \
  -m gpt-5.5 \
  -c 'model_reasoning_effort="xhigh"' \
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

- `-m gpt-5.5` — architect evaluates structural and contract choices, which require more nuanced reasoning than mechanical fact-checking.
- `-c 'model_reasoning_effort="xhigh"'` — architect runs at the deepest reasoning tier in the Phase 2 pipeline. Structural/contract decisions are the hardest to retract once the plan ships to implementation, so the per-round depth premium is justified despite the iteration loop's natural redundancy.
- `--sandbox read-only` — Gate 2 never writes.

For shared rationale (fast_mode, color, ephemeral, output-schema semantics, output-last-message, -C, stdin form), the canonical pattern, plugin_root resolution, and the stdin-hang background — see `code-implement-review/references/codex-command.md`.

## Persist

Always write the gate detail artifact to the exact `Artifact` path the planner supplied — typically `<session_dir>/phase2-g2-architect-{k}.md`.

On success (Codex exit 0 and `$out_file` is valid JSON conforming to the schema):

```markdown
# Phase 2 Gate Detail

- Gate: architect
- Round: {k}
- Verdict: {verdict}
- Engine: Codex
- Mode: {fresh|resume — what this gate actually ran as}
- Plan Fingerprint: {sha256:...}
- Blocking Reasons: {bullets from blocking_reasons, or "none"}
- Invalidated By: {reason or "none"}
- Next Action: {next_action}

## Structure Fit
{sections.structure_fit}

## Reuse and Boundaries
{sections.reuse_and_boundaries}

## Contracts and Security
{sections.contracts_and_security}

## Simulated Steps
{sections.simulated_steps}

## Evidence
{sections.evidence}
```

On failure: same fallback policy as Gate 1. Consult `code-implement-review/references/fallback-policy.md` for the category → fallback-allowed mapping. When persisting a Codex failure stub before fallback, keep the standard Phase 2 Gate Detail header (with `Engine: Codex`, `Mode: primary`) and write the canonical failure body documented in `code-implement-review/references/codex-failure-stub.md`. The body fills in `Outcome`, `Failure category`, and `Fallback allowed`; the Phase 2 header must not duplicate or contradict those values. If `Fallback allowed = no`, return `REJECT` with the stub as the canonical artifact.
