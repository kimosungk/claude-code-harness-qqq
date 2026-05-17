# Scope Lint — Phase 6 Step 1.4 (hard block)

Deterministic mechanical lint that runs after `phase1-tech-spec.md` is written (Phase 6 Step 1) and before Codex sanity-check (Step 1.5). Unlike sanity-check, this lint is a **hard block** — freeze cannot proceed until violations are resolved.

## Why a separate lint (not part of sanity-check)

`codex-sanity-check.md` is *advisory and judgmental* (decisions consistency, NLTP coverage, evidence gaps — subjective). Scope-lint is *mechanical and objective* (line counts, regex patterns, table cell structure). Mixing the two would force the sanity-check to be a hard block, which contradicts its "never block freeze" rule. Keeping them on separate tracks preserves the advisory semantics of sanity-check.

## Engine

**Bash (awk/grep) inline + Claude inline precision pass.** Codex is **not used** for this step:

- Line counts and regex patterns are 100% deterministic — `wc -l`, `awk`, `grep -cE` produce the same result every time with zero token cost.
- Codex is appropriate when the check requires semantic understanding (e.g., "does this decision contradict spec §X.Y?"). Scope-lint only asks structural questions.
- Adding a second Codex round to Phase 6 also doubles quota/latency/failure-recovery surface — ROI does not justify it.

Claude inline precision pass kicks in only when a Bash heuristic flags a candidate that could be a false positive (e.g., a single-line pure-expression function vs. a real implementation body). The precision pass is one short inline judgment, not a separate external call.

## Five Lint Categories

### Cat-1. Implementation code in spec body

Spec body (§1-§9, before the `<!-- audit-only-below -->` anchor) must contain decisions, evidence, and short rationale only — not actual implementation code.

**Allowed code forms:**
- TypeScript `interface` / `type` declarations (no method bodies)
- Function signatures: `function name(...): ReturnType;` — no body
- Struct / class field declarations (no method bodies)
- JSON-schema fragments (shape only)
- Mermaid / ASCII diagrams
- Single-line pure-expression functions: `const clamp = (v, lo, hi) => Math.max(lo, Math.min(v, hi));`

**Forbidden code forms (hard block):**
- `useState(`, `useRef(`, `useCallback(`, `useEffect(`, `useMemo(` followed by a body (more than one line of content between `{` and `}`)
- `if (`, `else if (`, `else {`, `switch (` followed by an implementation branch
- `try {`, `catch (`, `finally {` blocks
- `for (`, `while (`, `do {` loop bodies
- Method bodies on classes / objects (more than a signature)
- `return (` followed by a JSX tree
- Reducer-style switch-on-action pure functions with multi-case bodies (case 'X': return {...spread...})

**Section-aware whitelist:**
- §2 Data Model & State's `Store Shape (if stateful)` and `API Contract (shape only)` code fences are allowed to contain type definitions and field declarations. They are *not* allowed to contain method bodies — those still trigger Cat-1.

**Bash detection sketch:**

```bash
# Locate the audit anchor line number (default to file length if absent).
anchor_line=$(grep -n '<!-- audit-only-below' "$spec" | head -1 | cut -d: -f1)
anchor_line=${anchor_line:-$(wc -l < "$spec")}

# Slice body for inspection.
body=$(head -n "$anchor_line" "$spec")

# Pattern 1: hook calls followed by multi-line bodies.
echo "$body" | awk '
  /use(State|Effect|Ref|Callback|Memo)\(/ {capture=NR; depth=0}
  capture {
    depth += gsub(/\{/, "{")
    depth -= gsub(/\}/, "}")
    if (capture && depth == 0 && NR - capture > 1) print FILENAME":"capture": hook body > 1 line"
    if (depth == 0) capture=0
  }
'
# (additional patterns for if/else, try-catch, for/while, return ( ... JSX), reducer cases)
```

The Bash filter is broad; Claude inline pass confirms each candidate. Whitelist hits (§2 code fences) are stripped before passing to Claude.

### Cat-2. §5 ADR single DEC-N narrative > 30 lines

Within §5 Architecture Decisions (Detailed), each `### [DEC-N] ...` block must be ≤30 lines (raw `wc -l`, code fences and tables included).

**Bash detection:**

```bash
awk -v max=30 '
  /^### \[DEC-/ {
    if (start) {
      if ((NR - start - 1) > max) print "§5 block ["block"] = " (NR - start - 1) " lines (> " max ")"
    }
    start = NR; block = $0
  }
  END {
    if (start) {
      if ((NR - start) > max) print "§5 block ["block"] = " (NR - start) " lines (> " max ")"
    }
  }
' "$spec"
```

### Cat-3. §8 Phase1 Amendments row prose

§8 (Phase1 Amendments) table cells must be single-line, ≤120 chars. Any cell with `\n`, markdown `- ` bullet markers, or `<br>` triggers Cat-3.

**Bash detection:**

```bash
# Extract §8 table region, then scan rows for forbidden patterns.
awk '
  /^## 8\. Phase1 Amendments/ {region=1; next}
  /^## / && region {region=0}
  region && /^\| / {
    line=$0
    if (gsub(/\\n/, "\\n", line)) print "§8 row with literal \\n: " line
    if (line ~ /<br>/) print "§8 row with <br>: " line
    if (line ~ /^\| [^|]*\| - /) print "§8 row with bullet marker: " line
    # cell length cap — split on |, check each cell
    n = split(line, cells, "|")
    for (i=2; i<n; i++) {
      gsub(/^ +| +$/, "", cells[i])
      if (length(cells[i]) > 120) print "§8 row cell > 120 chars"
    }
  }
' "$spec"
```

### Cat-4. §7 Risks single row > 4 lines

§7 (Risks & Mitigations) table rows must be ≤4 lines per row. Mitigation prose inflating a row triggers Cat-4.

**Bash detection:**

```bash
awk '
  /^## 7\. Risks/ {region=1; next}
  /^## / && region {region=0}
  region && /^\| R-/ {
    row_lines = 1
    # peek ahead: if next line starts with whitespace + content (markdown table soft-wrap), count it.
    # In well-formed markdown, each table row is one line. Multi-line cells use <br>, which Cat-3 also catches in §7 if applied.
    # For § 7 specifically: scan the row's cells for newline indicators and accumulated cell length.
    n = split($0, cells, "|")
    total_chars = 0
    for (i=2; i<n; i++) {
      gsub(/^ +| +$/, "", cells[i])
      total_chars += length(cells[i])
    }
    # 4 lines × ~80 chars approx = 320 char ceiling on total row content as a proxy.
    if (total_chars > 320) print "§7 row R-* exceeds 4-line row budget (chars=" total_chars ")"
  }
' "$spec"
```

### Cat-5. Spec body length > 600 lines (HIGH override: 750)

Spec body = content before `<!-- audit-only-below -->` anchor (or the entire file when the anchor is absent — but absent anchor is itself a Cat-5 violation reported separately).

**Bash detection:**

```bash
anchor_line=$(grep -n '<!-- audit-only-below' "$spec" | head -1 | cut -d: -f1)
if [ -z "$anchor_line" ]; then
  echo "Cat-5: audit anchor missing — spec body cap unmeasurable"
  exit 1
fi
body_lines=$((anchor_line - 1))

# Read Complexity from spec header (Phase 0.5 or Phase 5 records "Complexity: HIGH (user-approved 750-line cap)").
complexity=$(grep -E '^> Complexity:' "$spec" | head -1 | sed 's/.*Complexity:[[:space:]]*//' | awk '{print $1}')
cap=600
if [ "$complexity" = "HIGH" ]; then
  cap=750
fi

if [ "$body_lines" -gt "$cap" ]; then
  echo "Cat-5: spec body = $body_lines lines (cap = $cap)"
fi
```

## Violation UX

For each lint finding, present to the user with file:line and ask one of three:

1. **Remove** — Auto-trim the violation. For Cat-1, replace the implementation code with just its interface/signature (Claude inline performs the trim). For Cat-3/Cat-4, compress the offending cell to fit the cap. For Cat-2, the user typically must edit the §5 block manually since narrative pruning requires judgment — offer a "soft trim" by removing the oldest bullet points and ask the user to confirm.
2. **Move** — Suggest a destination: PR description, commit message, or a `design-note.md` sidecar. The lint shows the extracted content; the user copy-pastes it after confirming.
3. **Acknowledge** — Explicit confirmation to keep as-is. Used rarely (e.g., a one-time exception for a domain-critical edge case). Recorded in §10 with a note: `Acknowledged Cat-N exception at {section} per user on {YYYY-MM-DD HH:MM}`.

## Artifact

Write one file per Phase 6 invocation:

`<session_dir>/phase1-tech-spec-scope-lint.md`

Structure:

```markdown
# Tech-Spec Scope Lint

- Engine: Bash + Claude inline
- Mode: hard-block
- Outcome: {clean | violations_present}
- Generated: {YYYY-MM-DD HH:MM}

## Violations
- [{Cat-N}] {section / line} — {one-line finding}
  - User choice: {Remove | Move | Acknowledge}
  - Resolution: {summary of action taken or note}

(_None._ when outcome is clean.)
```

When `outcome = clean`, Phase 6 proceeds to Step 1.5. When violations remain after user choices, Phase 6 stops and surfaces "scope-lint blocked freeze" — the user must restart Step 1.4 after editing.

## Re-running

Scope-lint is idempotent. After the user resolves violations and Edit-saves the spec, re-run the lint. Each run writes a fresh `phase1-tech-spec-scope-lint.md` (no round suffix; overwrite is intentional — the latest state is what matters for freeze).

## Reference patterns reused

- File structure mirrors `codex-sanity-check.md` Phase 6 Step 1.5 (prompt → output → artifact triple) for operational consistency, but no Codex call is made.
- §10 anchor convention (`<!-- audit-only-below -->`) is defined in `SKILL.md` Phase 6 Step 1 description; this lint enforces its presence (Cat-5 audit anchor missing).
