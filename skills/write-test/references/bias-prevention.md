# Bias prevention — why contract-first matters (and what the fork actually does)

Load this when:
- The caller asks "why can't you just read the implementation?"
- The contract surface is missing and you're tempted to peek at the impl
- You need to defend the no-impl-read rule
- You need to honestly explain the limits of the bias guard

This is not a procedure file. It explains the **why** so you can hold the line under pressure — and admits what the guard cannot do.

## The bias

When a test is written by someone who has just read the implementation:

1. The test asserts what the **code does**, not what the contract **specifies**.
2. The same wrong assumption that produced an off-by-one or null-handling bug in the implementation gets faithfully re-encoded in the test.
3. Edge cases the implementation forgot to handle remain absent from the test.
4. The test passes — production fails.

This is not a hypothetical. It's the dominant failure mode of "test-after" workflows. The test pyramid only protects you when the tests verify the **contract**, not the **code**.

## What the fork actually isolates (be honest)

`qqq:write-test` uses `context: fork` so this subagent has **no conversation memory** of the design choices, debugging steps, or wrong turns made in the calling session. That is what the fork isolates: prior reasoning, not filesystem access.

What the fork does **not** do:
- It does not prevent you from reading any file via the Read tool.
- It does not prevent you from `cat`/`grep`/`find`-ing the impl source via Bash.
- It does not provide cryptographic guarantees of any kind.

The fork plus the no-impl-read rule plus the **mandatory Reads disclosure** in your output is the complete bias guard:

- **Fork** removes prior bias from conversation context.
- **No-impl-read rule** is the behavioral protocol.
- **Reads disclosure** makes any violation auditable by the calling session.

If you violate the rule (deliberately or by accident), you must self-flag it in your output. That is non-negotiable. A silent violation is a worse outcome than a Skip with a confessed read.

## What counts as "contract"

✅ TypeScript type signatures and interfaces
✅ Zod schemas (the schema *is* the contract — schema files are fully readable)
✅ JSDoc on exported symbols
✅ Function signatures + parameter names
✅ Requirement spec / NLTP / user story
✅ Existing test files (as pattern reference, not as oracle)
✅ API spec documents (`<repo-root>/docs/api-specs/`)
✅ For bug fixes: the **buggy pre-fix code** (it represents the regression contract — what is currently wrong)

❌ The function body of newly-added/just-modified code in the change being tested
❌ Inline comments inside the new impl ("this handles the X case")
❌ Diff hunks of the new impl (the fix patch for a bug fix)
❌ Stack traces from a failing run of the new impl

Inline comments are tempting but disqualified — they're written by the same person/session as the impl and inherit the same blind spots.

## Defining "newly-added" precisely

"Newly-added or just-modified" code = the function bodies that were created or whose contents were edited in the change the caller is asking you to test. Concretely:

- Code introduced in the current PR or branch HEAD vs. main (if you're inside a PR-scoped review)
- Code edited in the immediately preceding turn of the calling session (if invoked right after impl)
- Code the user explicitly identifies as "just added" or "방금 만든"

The Zod schema/type definitions in the same file are NOT "newly-added function bodies" — they are contract surfaces and are readable. The forbidden surface is the function body that *consumes* or *implements* against the contract.

If you're unsure whether a file qualifies, **AskUserQuestion**: "Is `<path>` part of the change being tested? I need to know whether to treat its function bodies as forbidden."

## When to ask, not infer

If you find yourself thinking any of these, **AskUserQuestion**:

- "I'll just read the function to see what it should return when input is empty"
- "The types don't say what happens when X is null, but the impl probably handles it as Y"
- "Let me check the impl to figure out the error message"

The right phrasing of the question:

> The contract at `<path>` does not specify behavior for `<edge case>`. Should it (a) throw, (b) return `<default>`, or (c) something else? I won't infer from the implementation — that defeats the bias guard.

The user will either tell you, or they will admit the contract is incomplete (in which case the **first** action is to update the contract, then test).

## Bug-fix special case

For bug fixes in repeatedly-regressing areas (Required tier per the table):

- The **buggy pre-fix code** is readable. It defines what is currently wrong — the regression contract.
- The **fix patch** is NOT readable. Reading the fix lets you write a test that passes specifically because of how the fix was implemented, propagating the same potential blind spot.
- Workflow: read the buggy code + the bug report/symptom description → write a test that captures the symptom (it should fail on the unfixed code) → run against the fixed branch → verify it passes.

### Recovering the buggy pre-fix state

When the fix is committed, recover the buggy code via git (the skill pre-approves `git show`, `git diff`, `git log`, `git rev-parse`, `git status`):

```bash
# Identify the commit that introduced the fix
git log --oneline -- <path>

# Read the buggy version (the parent of the fix commit)
git show <fix-commit>^:<path>

# Or read the diff to spot what changed (note: this reveals the fix patch — only use if the buggy state alone is insufficient)
git diff <fix-commit>^ <fix-commit> -- <path>
```

Prefer `git show <fix-commit>^:<path>` (buggy state in isolation) over `git diff` (which reveals the fix). Use `git diff` only as a last resort and disclose it explicitly in the Reads disclosure with rationale.

When the fix is **uncommitted** (still in working tree), the buggy state is unrecoverable from git alone. **AskUserQuestion**: "The fix appears uncommitted. I cannot recover the buggy state from git. Provide either (a) the buggy code at the prior commit (e.g., reset and re-apply later), (b) a description of the symptom precise enough to write a falsifying test, or (c) a failing reproduction. Which can you provide?"

### When fix is already merged and you only have post-fix code

Same workflow with `git show <merge-commit>^:<path>`, identifying the merge commit via `git log --merges` or by the commit that the user provides.

## The Skip-first connection

Most invocations should Skip. Why? Because most of what people want to test:

- Trivial setters → no contract beyond "stores the value"
- Simple TQ wrappers → no contract beyond what the type already states
- Presentational UI → contract is visual, not behavioral

Skipping these is **defensible**, not lazy. A test that re-states the type signature against itself adds zero protection. You write tests for the cases where the contract is non-trivial and a wrong impl would silently violate it.

## Defending the rule to the caller

If the calling Claude session pushes back ("just look at the impl, it's fine"), respond with the Skip report or ask for the contract. Do not negotiate. The rule exists precisely because the caller's context is biased — that is the situation `context: fork` is designed for.

If you do read an impl file (e.g., to find a sibling test pattern, or for an existing-stable-code edge case), the Reads disclosure makes it visible. The caller can then assess whether the read was justified.
