# analysis-md-template — ANALYSIS.md canonical template

Read in Step 6. Write `$ARTIFACT_DIR/ANALYSIS.md` using the structure below.

## Template

```markdown
# <bug one-line summary> — Root-cause investigation

**Date:** <YYYY-MM-DD>
**Branch:** <current branch>
**Base commit:** <commit hash>
**Mode:** <mock | real>
**Headed:** <yes | no>
**Artifact dir:** <absolute path>

## Conclusion summary

<A single sentence. Technically precise. No hedging words. Evidence-based.>

## Repro environment

- dev command: `<the actual command used>`
- port: <port>
- Xvfb: `:<display>` / N/A
- playwright session: `dbg-<ID>`
- Repro scenario summary:
  - URL: ...
  - step 1: ...
  - step 2: ...
  - Bug trigger: ...

## Timeline capture method

`window.__debug` mutable array push. `console.log` is not used (avoids microtask-order perturbation).

Log points:
- `<scope>.<step>` — meaning

## Baseline timeline — bug reproduced

```
dt=   0ms  <scope>     <step>                <key>=<val>
dt=   5ms  <scope>     <step>                <key>=<val>
dt= 120ms  <scope>     <step>                <key>=<val>   ★ stuck here
...
```

Screenshot: `<path>` (confirms the narrow stuck range)

## Experiment N — <what changed>

### Hypothesis
<one sentence>

### Change
- File: `<path>:<line>`
- Change: `<line before>` → `<line after or // disabled>`

### Result timeline
```
dt=   0ms  <scope>     <step>                <key>=<val>
...
```

### Interpretation
<What changed vs. baseline / what didn't — which hypothesis is confirmed or refuted>

### Screenshot
<path>

## Root cause breakdown

### Phase 1. <first causal step>
<evidence-based explanation>

**Evidence**:
- Timeline row <n>: <value change>
- Source `<path>:<line>` — <relevant logic>

### Phase 2. <next>

### Phase 3. <…>

## Decisive evidence

<Excerpt the single strongest timeline block that grounds the one-line conclusion. No evidence, no conclusion.>

## Fix direction (memo — do not implement)

Ordered by priority:

1. **<candidate 1 title>**
   - Change site: `<path>:<line>`
   - Approach: <one paragraph>
   - Why it works: <reason>
   - Watch out: <side effects / caveats>

2. **<candidate 2>** — …

3. **<candidate 3>** — …

## Experiment artifacts

- `ydebug-baseline.json` — Baseline timeline
- `ydebug-exp1.json` — Experiment 1 timeline
- `ydebug-exp2.json` — …
- Screenshots: …

## Session closeout checklist

- [x] Source reverted (`git diff` is clean)
- [x] Dev server killed (PGID <N>)
- [x] Xvfb killed (:<display>) / N/A
- [x] Playwright session closed (`dbg-<ID>`)
- [x] MARKER / LOG removed
```

## Authoring principles

1. **Evidence first**: Every claim carries a timeline reference or file:line.
2. **No hedging**: "probably", "seems to" signal missing evidence. With evidence, use the declarative form.
3. **Reproducibility**: Another reader should arrive at the same conclusion from ANALYSIS.md alone.
4. **Isolate fix**: Fix direction stays in its memo section. The main body contains no fix implementation.
5. **Reference screenshots**: Always record the path when visual evidence exists. Useful for later comparison.

## Bad ANALYSIS.md examples

- ❌ "The Y axis looks wrong when narrow-zoomed" → **Express what's wrong with values**. e.g. "Y=[26.84, 30.61] fails to change even after full data [10.99, 31.05] is loaded."
- ❌ "It could probably be fixed by resetting autoRange" → **Fix direction goes to the memo with evidence**.
- ❌ Experiments without a baseline → Baseline is the comparison reference; always include it.
- ❌ Missing screenshots → Chart/WebGL defects are much stronger with visual evidence.
