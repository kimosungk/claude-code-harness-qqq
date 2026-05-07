# Fallback Policy

Read this only if `codex` is missing or the Codex attempt failed.

Claude fallback is allowed only for infrastructure failures.

## Allowed Fallback Reasons

- `which codex` fails
- auth failure
- quota/rate-limit exhaustion
- model unavailable / service overloaded
- transport/runtime failure

## Disallowed Fallback Reasons

- Codex returned a normal but weak answer
- Codex partially resolved the repo but left semantic choices unclear
- you simply prefer not to use Codex

## Useful stderr/stdout Hints

- Auth: `login`, `auth`, `unauthorized`, `forbidden`, `credential`
- Quota / rate limit: `rate limit`, `quota`, `capacity`, `too many requests`, `429`
- Model/service unavailable: `model unavailable`, `overloaded`, `service unavailable`, `503`
- Runtime / transport: `timed out`, `connection reset`, `transport`, `broken pipe`

If the failure matches an allowed reason, fallback may proceed. Otherwise stop with `BLOCKED`.
