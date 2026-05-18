# Fallback Policy

Read this only if `codex` is missing or the Codex attempt failed.

Claude fallback is allowed only when the failure category is infrastructure-class. The mapping below is authoritative; do not paper over `bug`-class failures with a fallback.

## Category → Fallback Mapping (authoritative)

Categorize the failure using `codex-failure-stub.md` first, then look up the category here.

| Category | Fallback allowed | Rationale |
|---|---|---|
| `missing_cli` | yes | binary absent — environment problem |
| `auth` | yes | infra-class — credential/session issue |
| `quota` | yes | infra-class — rate/quota/billing |
| `model_unavailable` | yes | infra-class — provider-side capacity |
| `transport` | yes | infra-class — network/runtime |
| `timeout` | yes | infra-class — wall-clock budget exceeded |
| `unsupported_config` | no | bug — fix the skill's config, do not paper over |
| `schema` | no | bug — model output failed schema; REJECT |
| `unknown` | no | uncategorized — REJECT and extend categorization patterns |

If `Fallback allowed = yes`, the calling skill may run its Claude fallback path. Otherwise it must persist the failure stub and return `REJECT`.

A single `unknown` is not a workflow defect, but if the same shape recurs, **extend the patterns in `codex-failure-stub.md`** instead of relaxing this table.

## Hard rules

- Do not fallback because Codex returned a normal but weak answer.
- Do not fallback because Codex returned malformed but semantically review-like output that still needs human judgment.
- Do not fallback because you simply prefer not to use Codex.
- Do not edit this mapping per-skill. If a category needs different behavior in a specific skill, the skill should detect and reject before getting here.
