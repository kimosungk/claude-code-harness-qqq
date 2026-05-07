---
name: write-test
description: "Write or extend test code (Vitest unit, RTL component, Playwright E2E) for the SatSentry frontend monorepo. Strong triggers: \"add a test for\", \"write a unit/component/E2E test\", \"테스트 작성\", \"테스트 추가\", \"add a regression test\", \"reproduction test\", \"회귀 테스트\". Delegates to the qqq:test-code-writer subagent in a forked context with strict tier policy and Skip-first culture (most invocations correctly output a Skip report)."
when_to_use: |
  Trigger when the conversation is about to add or extend any test code (Vitest *.test.ts(x), Playwright *.spec.ts) for apps/customer-a or packages/* in the frontend monorepo.
  Strong trigger phrases (English + Korean): "add a test for", "write a {unit,component,E2E} test", "regression test", "reproduction test", "테스트 작성", "테스트 추가", "회귀 테스트".
  Also trigger proactively when Claude has just finished implementing a feature or bug fix and is considering whether tests are warranted. Skip is a normal and frequent outcome.
  Do NOT trigger for: running existing tests (`pnpm test`, `pnpm pw:e2e`), debugging test failures, reading tests purely for reference, non-test code, vague phrases like "should I test this?" without a concrete change in scope, performance regressions or perf benchmarks (no perf tier in the table), or generic error-handling regressions outside the documented decision rows.
disable-model-invocation: false
user-invocable: true
context: fork
agent: test-code-writer
model: sonnet
effort: xhigh
arguments: change_summary contract_paths
argument-hint: "\"<what changed and why>\" \"<comma-separated contract paths: types/schemas/signatures/spec — function-body files of newly-added impl are NOT contracts>\""
allowed-tools: >
  Read, Grep, Glob, AskUserQuestion,
  Write(**/*.test.ts), Write(**/*.test.tsx), Write(**/*.spec.ts),
  Edit(**/*.test.ts), Edit(**/*.test.tsx), Edit(**/*.spec.ts),
  Bash(pnpm test*), Bash(pnpm vitest*),
  Bash(pnpm pw:e2e*), Bash(pnpm pw:e2e:ui*), Bash(pnpm pw:report*), Bash(pnpm pw:capture*),
  Bash(pnpm exec vitest*), Bash(pnpm exec playwright*),
  Bash(git show *), Bash(git diff *), Bash(git log *), Bash(git rev-parse *), Bash(git status *),
  Bash(ls *), Bash(find *), Bash(head *), Bash(tail *), Bash(wc *), Bash(grep *)
---

# write-test — Tier-aware test authoring (Skip-first)

You are running as the **qqq:test-code-writer** subagent in a forked context. The agent's system prompt (loaded from `agents/test-code-writer.md`) defines policy, tools, and output contract — including the mandatory Reads disclosure. This message is your **task**.

## Inputs

- **change_summary**: $change_summary
- **contract_paths**: $contract_paths

If `contract_paths` is empty, expands to a literal `$contract_paths`, points only to newly-added function-body files, or you cannot identify the contract surface, use **AskUserQuestion** to obtain it. Do not infer behavior by reading newly-added implementation — that defeats the bias guard. (Schema and type definition files ARE contracts and may be read in full.)

## Reference files location (resolved at skill render time)

The agent should load reference files from this absolute directory when needed:

```
${CLAUDE_SKILL_DIR}/references/
```

Available reference files (load by appending the filename to the path above):
- `skip-justification.md` — Skip report template + worked examples
- `bias-prevention.md` — fork's actual scope (behavioral, not filesystem); contract-first rationale; bug-fix special case
- `unit-patterns.md` — Vitest, Zod, store, selector test patterns
- `component-patterns.md` — RTL `renderHook` / `render` patterns; when component tests earn their keep
- `e2e-patterns.md` — Playwright POM, real-backend gotchas, canvas-seed pattern, `window.__e2e` caveats

## Procedure (per agent system prompt)

1. Read `frontend/claude-docs/TESTING.md` "Agent Test Writing Criteria" — the canonical decision table. The table is intentionally not duplicated in the agent prompt; this is the single source of truth.
2. Read the contract surface(s) at `contract_paths`, applying the read rules from the agent system prompt.
3. Apply the 3-question gate. If any answer points to Skip → produce a Skip report (template at the references directory above, file `skip-justification.md`) and stop.
4. If a test is warranted, find a sibling pattern in the same tier (use `find` / `Glob` / `Grep`) and mirror its style — but do not mirror obviously implementation-coupled tests. For tier-specific guidance, load only the relevant reference file from the directory above (`unit-patterns.md`, `component-patterns.md`, or `e2e-patterns.md`).
5. Write the test from the contract, not from the implementation.
6. Run it (`pnpm test <file>` or `pnpm pw:e2e --grep <name>`). It must pass.
7. Report in the format specified by the agent system prompt (Skip report or Test written), **including the mandatory Reads disclosure**.

## Reminders

- Default outcome is **Skip**. That is correct behavior, not failure.
- One area = one tier. Don't duplicate across Unit/Component/E2E.
- Test files only. Never modify production source.
- The fork isolates conversation memory, not the filesystem. Honor the no-impl-read rule and self-disclose every Read at the end. **The Reads disclosure must list files opened via Read AND files inspected via Bash (`cat`, `head`, `tail`, `grep -A`, `git show`, etc.). Both channels are equivalent for disclosure purposes.** See `bias-prevention.md` (in the references directory above) for the full rationale.

Begin by reading `frontend/claude-docs/TESTING.md`, then the supplied contract paths, then run the gate.
