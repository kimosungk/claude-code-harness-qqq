#!/usr/bin/env bash

set -euo pipefail

cwd=$(pwd)
agent_type="${QQQ_AGENT:-unknown}"
session_dir="${QQQ_SESSION_DIR:-$cwd}"

expected_artifact="phase1-spec.md"
# Guard against malformed state first — a half-rewind or manual rm can leave
# downstream artifacts without their upstream prerequisite. Flag it loudly
# instead of quietly advising the next downstream artifact.
if [[ -f "$cwd/phase2-code-plan.md" && ! -f "$cwd/phase1-tech-spec.md" ]]; then
  expected_artifact="phase1-tech-spec.md (MISSING — malformed state: phase2-code-plan.md exists without prerequisite)"
elif [[ -f "$cwd/phase3-implement-log.md" && ! -f "$cwd/phase2-code-plan.md" ]]; then
  expected_artifact="phase2-code-plan.md (MISSING — malformed state: phase3-implement-log.md exists without prerequisite)"
elif [[ -f "$cwd/phase1-spec.md" && ! -f "$cwd/phase1-tech-spec.md" ]]; then
  expected_artifact="phase1-tech-spec.md"
elif [[ -f "$cwd/phase1-tech-spec.md" && ! -f "$cwd/phase2-code-plan.md" ]]; then
  expected_artifact="phase2-code-plan.md"
elif [[ -f "$cwd/phase2-code-plan.md" && ! -f "$cwd/phase3-implement-log.md" ]]; then
  expected_artifact="phase3-implement-log.md"
elif compgen -G "$cwd/phase3-*-review-*.md" >/dev/null; then
  expected_artifact="worktree-merge or claude-works-completed archive"
fi

printf 'qqq session dir: %s\n' "$session_dir"
printf 'current cwd: %s\n' "$cwd"
printf 'qqq plugin dir: %s\n' "${QQQ_PLUGIN_DIR:-unknown}"
printf 'qqq skill root: %s\n' "${QQQ_SKILL_ROOT:-unknown}"
printf 'qqq agent root: %s\n' "${QQQ_AGENT_ROOT:-unknown}"
printf 'qqq skills and agents are preloaded; do not use env/grep or home-directory find to discover them.\n'
printf 'frozen artifacts: approved phase1-tech-spec.md (when present), approved phase2-code-plan.md, claude-works-completed/*, and .qqq.lock are read-only.\n'
if [[ "$agent_type" == "tech-interviewer" ]]; then
  printf 'tech-interviewer rule: phase1-tech-spec.md is your only write target; phase1-spec.md may only be edited after explicit user approval of a proposed diff (logged in §7 Phase1 Amendments).\n'
elif [[ "$agent_type" == "nltp-interviewer" ]]; then
  printf 'nltp-interviewer rule: phase1-nltp.md is your write target. Run the auto-review loop via qqq:nltp-reviewer before showing any draft, and re-invoke the reviewer once after each user revision; round artifacts phase1-nltp-review-{k}.md are owned by nltp-reviewer. NLTP is the completion criteria for downstream Phase 2 / Phase 3 — never invent scenarios outside the locked Coverage scope.\n'
elif [[ "$agent_type" == "nltp-reviewer" ]]; then
  printf 'nltp-reviewer rule: write only the round artifact phase1-nltp-review-{k}.md at the path the calling agent passes in. Never edit phase1-nltp.md or phase1-spec.md. Verdict is OKAY or REJECT only — caveats are owned by the calling agent.\n'
elif [[ "$agent_type" == "code-planner" ]]; then
  printf 'planner rule: phase2-code-plan.md is not final until the planner-owned Phase 2 review artifacts exist. Required inputs: phase1-spec.md + phase1-tech-spec.md; read phase1-ui-outline.md and phase1-nltp.md too when present.\n'
elif [[ "$agent_type" == "code-implementer" ]]; then
  printf 'implementer rule: phase3-implement-log.md is not final until reviewer artifacts exist. phase2-code-plan.md is the source of truth; phase1-tech-spec.md and phase1-nltp.md are read-only references only.\n'
else
  printf 'agent rule: follow artifact ownership; do not overwrite another phase agent'"'"'s files.\n'
fi
printf 'next expected artifact here: %s\n' "$expected_artifact"
