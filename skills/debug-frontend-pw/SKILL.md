---
name: debug-frontend-pw
description: "qqq:debug-frontend-pw — Investigate the root cause of frontend defects using playwright-cli and in-browser instrumentation. Injects window.__debug and source-level log points to collect baseline/experiment timelines, then writes ANALYSIS.md under claude-works. Does not fix bugs."
when_to_use: |
  Trigger only when the user explicitly states a root-cause investigation goal. Example triggers — "figure out with playwright why X behaves this way", "analyze the cause in the browser", "reproduce real behavior and capture a timeline". Do NOT trigger for bug fixes, UI behavior verification (ui-verifier), feature additions, or code reviews. A subagent may invoke this skill for defect investigation.
user-invocable: true
disable-model-invocation: false
model: sonnet
effort: high
arguments: bug_description headed mode
argument-hint: "\"<bug-description>\" <auto|yes|no> <mock|real>"
allowed-tools: >
  Read, Grep, Glob, AskUserQuestion,
  Write(./claude-works/**), Write(../claude-works/**), Write(../../claude-works/**), Write(../../../claude-works/**),
  Edit, Bash(pnpm *), Bash(npm *), Bash(node *),
  Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git branch *),
  Bash(git worktree list *),
  Bash(git checkout -- *),
  Bash(setsid *), Bash(kill *), Bash(pgrep *), Bash(pkill *),
  Bash(ss *), Bash(curl *), Bash(sleep *),
  Bash(Xvfb *), Bash(xvfb-run *),
  Bash(playwright-cli *),
  Bash(mkdir -p *),
  Bash(ls *), Bash(cat *), Bash(grep *), Bash(awk *), Bash(head *), Bash(tail *), Bash(wc *),
  Bash(date *), Bash(env *),
  Bash(cp /tmp/* *), Bash(cp * /tmp/*),
  Bash(rm /tmp/*), Bash(rm -f /tmp/*),
  Bash(source /tmp/*)
---

# debug-frontend-pw — Playwright-driven Frontend Defect Root-Cause Investigation

**This skill does not fix bugs.** It reproduces the scenario in a real browser, collects timeline evidence via instrumentation, and identifies the **cause**. Fix implementation belongs to a separate session.

## Hard rules

1. **No logic changes**: Business logic must not be modified. Observation/experiment source edits are allowed only when tagged with a `// [DBG]` marker, and must all be reverted in teardown via `git checkout -- <files>`.
2. **Work on the current branch**: This skill does not create worktrees. If the user wants to analyze in a worktree, they must create it **before** invoking the skill and invoke from inside it.
3. **Clean up every resource**: The dev server, Xvfb, playwright-cli session, and MARKER files must be torn down at the end. Best-effort cleanup must still run on user cancellation.
4. **Conclusions require evidence**: Draw conclusions from `window.__debug` timelines and screenshots — never from speculation. No unsupported claims.
5. **Fixed ANALYSIS.md path**: `<claude-works>/<YYYY-mm-dd>_<title>/ANALYSIS.md`. See Step 0 for the `claude-works` resolution rules.

## Arguments

| Arg | Position | Values | Default |
|---|---|---|---|
| `$bug_description` | 1 | Defect description (quote if multi-word) | required |
| `$headed` | 2 | `auto` \| `yes` \| `no` | `auto` |
| `$mode` | 3 | `mock` \| `real` | `mock` |

`$headed=auto` resolution: if any of the following keywords appear in `bug_description` or the collected repro scenario, use headed; otherwise headless.

```
mousemove mousedown mouseup mousewheel wheel drag dblclick
dispatchEvent MouseEvent PointerEvent
canvas WebGL SciChart chart zoom pan hover tooltip
```

## Defaults (not changeable via arguments)

- **port**: random 55000–55999, strictPort, up to 3 retries on conflict.
- **worktree**: work in current cwd. The skill never creates a worktree.
- **dev command**: read `<claude-works>/debug-frontend-pw.devcmd` if present; otherwise use the built-in default.
  - Built-in default (mock): `VITE_USE_MOCK=true pnpm dev`
  - Built-in default (real): `pnpm dev`
  - See `references/env-isolation.md` for the file format.
- **__debug entries cap**: 1000. Overflow is reported in a warning.

## Workflow

Standard 6-step flow. Read each `references/*.md` **only when the step requires it** — never load all at once.

### Step 0 — Resolve claude-works location + decide topic

```bash
cwd_has_cw=$( [ -d "./claude-works" ] && echo 1 || echo 0 )
fe_has_cw=$( [ -d "./frontend/claude-works" ] && echo 1 || echo 0 )
fe_exists=$( [ -d "./frontend" ] && echo 1 || echo 0 )
```

Decision tree:
1. `cwd_has_cw=1 && fe_has_cw=0` → `./claude-works/`
2. `cwd_has_cw=0 && fe_has_cw=1` → `./frontend/claude-works/`
3. `cwd_has_cw=1 && fe_has_cw=1` → ask the user via AskUserQuestion
4. `cwd_has_cw=0 && fe_has_cw=0 && fe_exists=1` → ask: create `./frontend/claude-works/` or `./claude-works/`
5. Otherwise → create `./claude-works/`

Topic slug:
- Derive a kebab-case slug from `$bug_description`, max 40 chars, Korean characters allowed
- If ambiguous or too long, present via AskUserQuestion and let the user adjust

Finalize `ARTIFACT_DIR="$CLAUDE_WORKS/$(date +%Y-%m-%d)_<slug>"` and `mkdir -p`.

### Step 1 — Environment isolation (dev server + [Xvfb])

**Read `references/env-isolation.md` first**, then follow it exactly.

Key points:
- Sweep only dead MARKER files (never touch live ones)
- Generate a unique `UI_DEBUG_PW_ID`
- Try a random port up to 3 times
- Launch the dev server under `setsid -f` in a new process group; record the PGID
- Read the devcmd file (choose `mock` or `real` per `$mode`)
- Wait up to 30s via `curl` for vite to respond
- Record `UI_DEBUG_PW_ID`, `PGID`, `PORT`, `LOG` to MARKER

If `$headed` resolves to `yes` and `$DISPLAY` is empty, read `references/xvfb-setup.md` and start Xvfb on a random display (N = 80..99). Append the Xvfb PID to MARKER.

### Step 2 — Collect repro scenario + finalize headed=auto

If the user did not supply a repro scenario, collect one via AskUserQuestion:
- Starting URL / route
- Interaction steps (click, type, drag coordinates, dblclick, etc.)
- Expected vs. actual behavior (defect symptom)
- What UI element or value to observe

Re-evaluate `$headed=auto` against the collected scenario; if any keyword matches, use headed, otherwise headless.

### Step 3 — Start the playwright session + inject instrumentation

Session name convention: `dbg-$UI_DEBUG_PW_ID` (prevents collision with parallel skill instances).

```bash
source "$MARKER"
SESSION="dbg-$UI_DEBUG_PW_ID"
BASE_URL="http://127.0.0.1:$PORT"

# DISPLAY prefix is required only when running headed
[ "$HEADED" = "yes" ] && DISP_PREFIX="DISPLAY=:$XVFB_DISPLAY" || DISP_PREFIX=""
$DISP_PREFIX playwright-cli -s=$SESSION open "$BASE_URL" $([ "$HEADED" = "yes" ] && echo "--headed")
```

Then read `references/playwright-cli-tips.md` + `references/observation-injection.md` and:
- Inject the `window.__debug` infrastructure via eval
- Navigate to the target page following the repro scenario
- Measure canvas/WebGL element coordinates if applicable
- If needed, locate the target source file and insert `// [DBG]`-marked log points (use Edit; include the required biome-ignore comment)
- Wait for HMR (look for an `hmr update` line in the log)
- Reload, then re-inject `window.__debug`

### Step 4 — Capture the baseline timeline

1. Call `__debug.clear()`
2. Execute the scenario up to the line just before the "bug trigger"
3. Call `__debug.clear()` again (drop noise)
4. Execute the trigger (e.g., dispatch dblclick)
5. Sleep 2–5s (wait for async data fetches, etc.)
6. Save a screenshot
7. Dump the timeline JSON to the artifact dir:
   ```bash
   playwright-cli -s=$SESSION eval "() => JSON.stringify(window.__debug.dump())" --raw \
     > "$ARTIFACT_DIR/ydebug-baseline.json"
   ```
8. Convert the timeline into a human-readable table (python one-liner or jq)

**If the bug does not reproduce in baseline** — scenario is insufficient, or the source edit is masking it. Roll back any source change and re-confirm the scenario via AskUserQuestion.

### Step 5 — Hypothesis experiments (optional, recommended ≤ 3)

For each experiment:
1. Write the hypothesis in one sentence (appended to `ANALYSIS.md`)
2. Make the minimum change (comment out one line or swap a value) — always tag `// [DBG-exp]`
3. Wait for HMR
4. `__debug.clear()` → reload → re-inject → re-run the scenario
5. Save `ydebug-expN.json` and a screenshot
6. Diff 1–2 timeline rows against baseline and record in ANALYSIS.md

Do not stack changes across experiments. Each experiment must start from **baseline after reverting the previous experiment** (single-variable principle).

If three experiments fail to isolate the cause, ask the user via AskUserQuestion for additional hypotheses.

### Step 6 — Generate ANALYSIS.md + teardown

Read `references/analysis-md-template.md` and write `$ARTIFACT_DIR/ANALYSIS.md` using the template.

Teardown checklist (sequential, run each step even if a prior one failed):

```bash
# 1. Revert source edits
git diff --name-only | while read f; do
  # Only revert files containing a [DBG] marker (safety guard)
  git diff "$f" | grep -q '\[DBG' && git checkout -- "$f"
done

# 2. Close the playwright session
source "$MARKER"
playwright-cli -s="dbg-$UI_DEBUG_PW_ID" close 2>/dev/null || true

# 3. Kill the dev server (env-tag guard)
if grep -qaz "UI_DEBUG_PW_ID=$UI_DEBUG_PW_ID" "/proc/$PGID/environ" 2>/dev/null; then
  kill -TERM -"$PGID" 2>/dev/null
  sleep 1
  kill -KILL -"$PGID" 2>/dev/null
fi

# 4. Kill Xvfb (if headed)
[ -n "$XVFB_PID" ] && kill -TERM "$XVFB_PID" 2>/dev/null

# 5. Remove MARKER / LOG
rm -f "$MARKER" "$LOG"

# 6. Verify the working tree is clean (ignore untracked claude-works)
git diff --quiet && echo "source tree clean" \
  || echo "WARN: uncommitted changes remain: $(git diff --name-only)"
```

## Return format

On completion, report back to the main session with:

```
**Root cause finding**

[one-line conclusion]

**Artifacts**
- ANALYSIS.md: <absolute path>
- Baseline timeline: <path>/ydebug-baseline.json
- Experiment timelines: <list>
- Screenshots: <list>

**Fix direction (memo — do not implement)**
- [candidate 1]
- [candidate 2]

**Teardown status**
- Source reverted: ✓ / ✗ (remaining files)
- Dev server: ✓ / ✗
- Xvfb: ✓ / ✗ / N/A
- Playwright session: ✓ / ✗
```

## Failure-mode handling

| Failure | Action |
|---|---|
| Dev server fails 3x | Abort; report the `$LOG` path |
| Xvfb not installed | Print `apt install xvfb` guidance; propose a headless fallback via AskUserQuestion |
| playwright-cli not installed | Abort with an install-guidance message |
| HMR timeout (5s) | Force reload; if that fails, restart the dev server |
| Repro fails | Re-confirm the scenario via AskUserQuestion; revert edits and retry |
| User cancels | Run the teardown trap (checklist in order) |

## Parallel-execution safety

- `UI_DEBUG_PW_ID="uidbg-$(date +%s)-$$-$RANDOM"` guarantees uniqueness
- Port / Xvfb display / playwright session name / MARKER filename are all ID-derived
- Only dead MARKERs are swept; live ones are never touched (`kill -0 -PGID` check)

## References (progressive disclosure)

Read only at the point each step needs it. Do not load them all at once.

| Step | Reference | Purpose |
|---|---|---|
| 1 | `references/env-isolation.md` | MARKER/PGID/setsid/port/devcmd bootstrap script |
| 1 | `references/xvfb-setup.md` | Headed browser when DISPLAY is missing |
| 3 | `references/playwright-cli-tips.md` | Sessions, eval, dblclick limitations, canvas coordinates |
| 3 | `references/observation-injection.md` | `window.__debug` + source log markers |
| 3,4 | `references/react-timing.md` | Effect/rAF/HMR ordering; why to avoid console.log |
| 3,4 | `references/scichart-tips.md` | Appendix for chart/WebGL defects |
| 6 | `references/analysis-md-template.md` | ANALYSIS.md canonical template |

---

**Final mandate**: The final message must explicitly report teardown completion. If any step is incomplete, list the affected paths so the user can finish cleanup manually.
