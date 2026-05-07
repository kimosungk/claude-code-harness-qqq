# Codex Primary Path — Gate 3 (Critic)

Read this before the first review attempt of the round.

## Inputs

The planner sends a structured contract via `Task`. Use these fields verbatim:

- `Plan` — absolute path to `phase2-code-plan.md`
- `Session dir` — absolute session directory
- `Round` — integer `{k}`
- `Artifact` — absolute path the gate detail file must be written to (typically `<session_dir>/phase2-g3-critic-{k}.md`)
- `Mode` — `fresh` or `resume`
- `Plan fingerprint`, `Invalidated by`, `Change summary` — context
- `Handoff` — combined explorer + architect summaries from Gate 1 and Gate 2; treat as prior verified context, not a request to repeat the work

Required-read files (when present in the session dir):

- `phase2-code-plan.md`
- `phase1-tech-spec.md` (locked scope baseline for drift detection)
- `phase1-spec.md`
- `phase1-ui-outline.md`
- `phase1-nltp.md`
- plan-referenced repo files needed to validate failure modes or rollback coverage

## Preflight

1. `which codex`
2. Read each required input file from the session dir.
3. Decide whether `Mode: resume` is usable. If the prior session id is empty or premortem context is invalid, downgrade to `fresh` and record the reason.

## Output Schema

The verdict shape is contractually pinned by `references/verdict.schema.json` (next to this file). Codex must return JSON conforming to that schema — verdict, blocking_reasons, next_action, and a sections object containing the markdown bodies for each gate section. The persist step adds engine, mode, round, plan fingerprint, and invalidated-by metadata; do not ask Codex to produce those.

`ARCH_RECHECK` is a reserved string value the model may put inside `blocking_reasons` when architecture is the root cause and a same-round Gate 2 re-entry is needed. Treat it as a distinct blocking signal — the planner depends on it for routing.

## Prompt Template

Write this body to a prompt file under the session dir (see Command for the exact path). Do not pass it as an argv positional — argv transport is fragile for multi-KB prompts and Codex's documented stdin behavior makes it unsafe to mix argv prompt with an open stdin.

```text
You are Gate 3 (Critic) of the Phase 2 review pipeline. Run a premortem on the current plan. Do not redo Gate 1 fact verification or Gate 2 structure design. Return JSON conforming to the supplied schema.

## Round Context
- Round: {k}
- Mode: {fresh|resume}
- Plan fingerprint: {sha256:...}
- Invalidated by: {reason or "none"}
- Change summary:
{change summary}
- Handoff (Gate 1 explorer summary + Gate 2 architect summary, treat as prior verified context):
{handoff}

## Inputs
1. Spec (frozen):
<paste phase1-spec.md>

2. Tech spec (frozen, locked scope):
<paste phase1-tech-spec.md>

3. UI outline (when present):
<paste phase1-ui-outline.md or "N/A">

4. NLTP (when present):
<paste phase1-nltp.md or "N/A">

5. Plan under review:
<paste phase2-code-plan.md>

## Gate scope
- Race conditions and stale cache risks
- Unmount/lifecycle hazards
- Mock-vs-real drift
- Performance regressions
- Rollback and recovery gaps
- Observability blind spots
- Scope creep and intent drift relative to phase1-tech-spec.md (locked scope baseline)
- NLTP coverage gaps (when phase1-nltp.md is present, count uncovered scenarios as drift)

## Verdict rules
- "OKAY" when the plan's likely failure modes are covered by mitigations, tests, rollback, and observability.
- "REJECT" when the plan leaves a plausible high-severity failure mode unmitigated, drifts beyond locked scope, leaves significant NLTP scenarios unaddressed, or needs architecture recheck.
- If architecture is the root cause of a blocking risk, include the literal token "ARCH_RECHECK" inside blocking_reasons (this signals the planner to re-run Gate 2 next round).
- blocking_reasons must be non-empty when verdict is REJECT, each one keyed to file:line, exact file path, or the literal "ARCH_RECHECK".

## Section rules
Each section value is a markdown string rendered verbatim under its header. Anchor every claim to file:line.
- premortem_risks — ranked list of failure modes with severity and likelihood notes.
- rollback_and_observability — what fails open, what fails closed, what is observable when it does.
- scope_drift_check — comparison against phase1-tech-spec.md locked scope; NLTP coverage gaps when applicable.
- simulated_steps — a short walkthrough of the highest-risk step.
- evidence — concise list of the key file:line anchors used to form the verdict.

## Output rules
- Output the JSON object only. No prose preamble. No code fence around the JSON.
- Do not include engine, mode, round, plan_fingerprint, or invalidated_by — the persist step adds those.
```

## Command

```bash
prompt_file="<session_dir>/phase2-g3-critic-codex-prompt-{k}.md"
out_file="<session_dir>/phase2-g3-critic-codex-output-{k}.md"
schema_file="<plugin_root>/skills/code-plan-review-critic/references/verdict.schema.json"

# Write the prompt body (template above, with sections filled in) to $prompt_file
# using the Write tool. Do not use mktemp — it is not in the tool allowlist.

codex exec \
  -m gpt-5.5 \
  -c 'model_reasoning_effort="high"' \
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

- `-m gpt-5.5` — premortem requires judgment beyond mechanical matching; the heavier model is appropriate.
- `-c 'model_reasoning_effort="high"'` — Gate 3 catches what the iteration loop will then have to redo; `high` balances catch rate against per-call cost across the loop.
- `--sandbox read-only` — Gate 3 never writes.

For shared rationale (service_tier, fast_mode, color, ephemeral, output-schema semantics, output-last-message, -C, stdin form), the canonical pattern, plugin_root resolution, and the stdin-hang background — see `code-implement-review/references/codex-command.md`.

## Persist

Always write the gate detail artifact to the exact `Artifact` path the planner supplied — typically `<session_dir>/phase2-g3-critic-{k}.md`.

On success (Codex exit 0 and `$out_file` is valid JSON conforming to the schema):

```markdown
# Phase 2 Gate Detail

- Gate: critic
- Round: {k}
- Verdict: {verdict}
- Engine: Codex
- Mode: {fresh|resume — what this gate actually ran as}
- Plan Fingerprint: {sha256:...}
- Blocking Reasons: {bullets from blocking_reasons, including the literal ARCH_RECHECK token when present, or "none"}
- Invalidated By: {reason or "none"}
- Next Action: {next_action}

## Premortem Risks
{sections.premortem_risks}

## Rollback and Observability
{sections.rollback_and_observability}

## Scope Drift Check
{sections.scope_drift_check}

## Simulated Steps
{sections.simulated_steps}

## Evidence
{sections.evidence}
```

On failure: same fallback policy as Gate 1. Consult `code-implement-review/references/fallback-policy.md` for the allowed-reasons list. When persisting a Codex failure stub before fallback, keep the standard Phase 2 Gate Detail header (with `Engine: Codex`, `Outcome: FAILURE — falling back to Claude`) and write the canonical failure body documented in `code-implement-review/references/codex-failure-stub.md`.
