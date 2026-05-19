#!/usr/bin/env bash

set -euo pipefail

# qqq-context (v2.3 — Q3=다)
# SessionStart hook. Two responsibilities:
#   1. Recover phase context from artifact files in the current worktree.
#   2. Warn about uncommitted phase{N}-*.md (lost if worktree is deleted).
# Replaces the legacy 66-line version that referenced .qqq.lock, .qqq/session.json,
# and per-agent rule strings — all retired in migration v2.3.

cwd=$(pwd)

is_session_dir() {
  local dir="$1"
  [[ -f "$dir/phase0-issue.md" \
    || -f "$dir/phase1-spec.md" \
    || -f "$dir/phase1-tech-spec.md" \
    || -f "$dir/phase2-code-plan.md" \
    || -f "$dir/phase3-implement-log.md" ]]
}

if ! is_session_dir "$cwd"; then
  exit 0
fi

# Phase inference — last artifact present determines the next expected action.
# Phase commands dispatch as --agent qqq:<agent>; slash forms remain available
# for ad-hoc reentry.
next=""
if [[ -f "$cwd/phase3-implement-log.md" ]]; then
  next="phase3 done — review diff, then qqq merge"
elif [[ -f "$cwd/phase2-code-plan.md" ]]; then
  next="phase3 — qqq implement  (agent qqq:code-implementer; needs phase2-review-state.json review_loop_completed: true)"
elif [[ -f "$cwd/phase1-tech-spec.md" ]]; then
  next="phase2 — qqq plan  (agent qqq:code-planner)"
elif [[ -f "$cwd/phase1-spec.md" ]]; then
  next="phase1d — qqq tech-spec  (agent qqq:tech-interviewer; optional: qqq ui, qqq nltp)"
elif [[ -f "$cwd/phase0-issue.md" ]]; then
  next="phase1 — qqq clarify  (agent qqq:req-clarifier)"
fi

printf 'qqq worktree: %s\n' "$cwd"
[[ -n "$next" ]] && printf 'next expected: %s\n' "$next"
printf 'frozen: claude-works-completed/* is read-only.\n'

# Uncommit warning — phase{N}-*.md changes are lost when the worktree is deleted.
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  uncommit=$(git -C "$cwd" status --short 2>/dev/null | grep -E ' phase[0-9]+-' || true)
  if [[ -n "$uncommit" ]]; then
    printf 'WARNING uncommitted qqq artifacts (commit before claude rm / Ctrl+X to avoid loss):\n%s\n' "$uncommit"
  fi
fi
