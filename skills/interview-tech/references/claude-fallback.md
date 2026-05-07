# Claude Fallback — Tech-Spec Sanity Check

Read this only when the Codex sanity-check attempt failed for an infrastructure reason (the allowed list lives in `code-implement-review/references/fallback-policy.md` — same list applies here).

## When to use

Codex-first is mandatory. Fallback is allowed only when one of these is true:

- `which codex` failed
- auth failure surfaced from `codex exec` stderr
- quota / rate-limit / 429 / 503 surfaced from stderr
- transport / runtime failure (broken pipe, timeout, stdin-wait hang)
- `$out_file` is missing / empty / not parseable JSON / fails schema validation despite Codex exit 0

Fallback is NOT allowed because:

- Codex returned a clean `clean` outcome and you'd prefer to double-check
- Codex returned findings you disagree with
- You simply prefer to do it yourself

## What to do

The interview-tech skill runs on a capable Claude model (opus). Do the sanity-check inline using the same scope and the same output shape. Do not delegate to a subagent; this is a one-shot single-prompt step.

### Inputs

Same as the Codex path:

- `phase1-spec.md` (frozen)
- `phase1-tech-spec.md` (just-written draft)
- `phase1-ui-outline.md` (when present)
- `phase1-nltp.md` (when present)

### Procedure

1. Read all input files fully.
2. Apply the three category checks exactly as scoped in `codex-sanity-check.md` Scope:
   - spec_consistency
   - evidence_gap
   - nltp_coverage
3. Forbidden categories rule applies identically — if a candidate finding requires subjective judgment to defend, omit it.
4. Build the JSON object yourself in memory. Validate it against `references/sanity-check.schema.json` mentally (outcome enum, findings array, per-finding required keys, severity enum).
5. Write the raw JSON to `<session_dir>/phase1-tech-spec-sanity-output.json` so the audit trail is symmetric with the Codex path.
6. Render the markdown artifact at `<session_dir>/phase1-tech-spec-sanity.md`:

```markdown
# Tech-Spec Sanity Check

- Engine: Claude (fallback)
- Mode: fallback
- Fallback trigger: {one-line infra reason — quote stderr or describe transport issue}
- Outcome: {clean | findings_present}
- Generated: {YYYY-MM-DD HH:MM}
- Advisory only — does not block freeze.

## Findings
- [{severity}] {category} · {tech_spec_location} — {finding}

(Repeat per finding. Render `_None._` when outcome is clean.)
```

The Codex failure stub written before fallback (header `# Tech-Spec Sanity Check — Codex Failure`) is replaced by the file above. Do not preserve both — the fallback artifact is the canonical record.

## Hard rules

- Do not extend the scope. The three categories are exhaustive.
- Do not include subjective findings even when "obvious". Omit when in doubt.
- Do not block the user from freezing. The artifact is advisory; Phase 6 Step 2 simply surfaces the findings in the summary.
- Do not retry Codex inline. If Codex failed, this fallback is the single attempt.
