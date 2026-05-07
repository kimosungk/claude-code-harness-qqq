#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd "$script_dir/../.." && pwd)

payload=$(cat)
if [[ -z "$payload" ]]; then
  payload='{}'
fi

json_get() {
  local filter="$1"
  jq -r "$filter // empty" <<<"$payload" 2>/dev/null || true
}

resolve_agent_type() {
  local resolved
  resolved=$(json_get '.agent_type')
  if [[ -z "$resolved" ]]; then
    resolved=$(json_get '.subagent_type')
  fi
  if [[ -z "$resolved" ]]; then
    resolved=$(json_get '.task.agent_type')
  fi
  if [[ -z "$resolved" ]]; then
    resolved=$(json_get '.task.subagent_type')
  fi
  if [[ -z "$resolved" ]]; then
    resolved="${QQQ_AGENT:-}"
  fi
  # Strip plugin namespace prefix so both "qqq:nltp-interviewer" and
  # "nltp-interviewer" resolve to the same short name for matching.
  resolved="${resolved##*:}"
  printf '%s\n' "$resolved"
}

normalize_path() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  if [[ "$raw" != /* ]]; then
    raw="$PWD/$raw"
  fi
  printf '%s\n' "$raw" | sed 's#//*#/#g'
}

relative_to_project() {
  local abs="$1"
  if [[ "$abs" == "$project_root/"* ]]; then
    printf '%s\n' "${abs#"$project_root"/}"
  else
    printf '%s\n' "$abs"
  fi
}

block() {
  local reason="$1"
  printf '[qqq-hooks] blocked edit: %s\n' "$reason" >&2
  exit 2
}

matches_any_agent() {
  local agent="$1"
  shift
  local allowed
  for allowed in "$@"; do
    if [[ "$agent" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

phase_artifact_owner() {
  local base="$1"
  case "$base" in
    # Phase 1 artifacts
    phase1-spec.md)
      printf 'req-clarifier\n'
      ;;
    phase1-ui-outline.md|phase1-ui-outline.html)
      printf 'ui-outliner\n'
      ;;
    phase1-nltp.md)
      printf 'nltp-interviewer\n'
      ;;
    phase1-nltp-review-*.md)
      printf 'nltp-reviewer\n'
      ;;
    phase1-tech-spec.md)
      printf 'tech-interviewer\n'
      ;;
    # Phase 2 artifacts
    phase2-code-plan.md)
      printf 'code-planner\n'
      ;;
    phase2-review-log.md|phase2-review-state.json|phase2-review-round-*.md)
      printf 'code-planner\n'
      ;;
    phase2-g1-explorer-*.md)
      printf 'code-plan-review-explorer\n'
      ;;
    phase2-g2-architect-*.md)
      printf 'code-plan-review-architect\n'
      ;;
    phase2-g3-critic-*.md)
      printf 'code-plan-review-critic\n'
      ;;
    # Phase 3 artifacts
    phase3-implement-log.md)
      printf 'code-implementer\n'
      ;;
    phase3-*-review-*.md)
      printf 'code-implement-reviewer\n'
      ;;
    # Rebase conflict artifacts (any phase)
    rebase-conflict-*.md|rebase-conflict-*.json)
      printf 'rebase-conflict-resolver\n'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

file_path=$(json_get '.tool_input.file_path')
if [[ -z "$file_path" ]]; then
  file_path=$(json_get '.tool_input.path')
fi
if [[ -z "$file_path" ]]; then
  file_path=$(json_get '.file_path')
fi

if [[ -z "$file_path" ]]; then
  exit 0
fi

agent_type=$(resolve_agent_type)

abs_path=$(normalize_path "$file_path")
rel_path=$(relative_to_project "$abs_path")
base_name=$(basename "$rel_path")

# ── Runtime-owned files ────────────────────────────────────────────────────
if [[ "$base_name" == ".qqq.lock" ]]; then
  block ".qqq.lock is runtime-owned and may not be edited by Claude"
fi

# ── Completed archive is frozen ────────────────────────────────────────────
if [[ "$rel_path" == claude-works-completed/* || "$rel_path" == */claude-works-completed/* ]]; then
  block "completed archive artifacts are frozen: $rel_path"
fi

# ── Human-approved artifacts are frozen ───────────────────────────────────
if [[ "$base_name" == "phase2-code-plan.md" && -f "$abs_path" ]]; then
  if grep -q '^Status: Approved by user' "$abs_path" 2>/dev/null; then
    block "approved phase2-code-plan.md is frozen after human approval"
  fi
fi

if [[ "$base_name" == "phase1-tech-spec.md" && -f "$abs_path" ]]; then
  if grep -q '^Status: Approved by user' "$abs_path" 2>/dev/null; then
    block "approved phase1-tech-spec.md is frozen after human approval"
  fi
fi

# ── Phase artifact ownership checks ───────────────────────────────────────
artifact_owner=$(phase_artifact_owner "$base_name")

if [[ "$artifact_owner" == "req-clarifier" ]]; then
  # phase1-spec.md is primarily owned by req-clarifier, but tech-interviewer
  # may amend it via the Phase 4 Amendment Gate after explicit user approval.
  matches_any_agent "$agent_type" req-clarifier tech-interviewer \
    || block "$rel_path is owned by req-clarifier (and amendable by tech-interviewer) — current agent: ${agent_type:-main-session}"
  exit 0
fi

if [[ "$artifact_owner" == "ui-outliner" ]]; then
  matches_any_agent "$agent_type" ui-outliner \
    || block "$rel_path is owned by ui-outliner (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "nltp-interviewer" ]]; then
  matches_any_agent "$agent_type" nltp-interviewer \
    || block "$rel_path is owned by nltp-interviewer (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "nltp-reviewer" ]]; then
  # nltp-interviewer spawns nltp-reviewer which writes the review file.
  # Allow nltp-interviewer as the parent caller as well.
  matches_any_agent "$agent_type" nltp-reviewer nltp-interviewer \
    || block "$rel_path is owned by nltp-reviewer (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "tech-interviewer" ]]; then
  matches_any_agent "$agent_type" tech-interviewer \
    || block "$rel_path is owned by tech-interviewer before approval (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "code-planner" ]]; then
  matches_any_agent "$agent_type" code-planner \
    || block "$rel_path is owned by code-planner before approval (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "code-plan-review-explorer" ]]; then
  # code-planner orchestrates these reviewers and may also write their files.
  matches_any_agent "$agent_type" code-planner code-plan-review-explorer \
    || block "$rel_path is owned by code-plan-review-explorer (planner may also write it) — current agent: ${agent_type:-main-session}"
  exit 0
fi

if [[ "$artifact_owner" == "code-plan-review-architect" ]]; then
  matches_any_agent "$agent_type" code-planner code-plan-review-architect \
    || block "$rel_path is owned by code-plan-review-architect (planner may also write it) — current agent: ${agent_type:-main-session}"
  exit 0
fi

if [[ "$artifact_owner" == "code-plan-review-critic" ]]; then
  matches_any_agent "$agent_type" code-planner code-plan-review-critic \
    || block "$rel_path is owned by code-plan-review-critic (planner may also write it) — current agent: ${agent_type:-main-session}"
  exit 0
fi

if [[ "$artifact_owner" == "code-implementer" ]]; then
  matches_any_agent "$agent_type" code-implementer \
    || block "$rel_path is owned by code-implementer (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "code-implement-reviewer" ]]; then
  # code-implementer spawns code-implement-reviewer; allow parent as well.
  matches_any_agent "$agent_type" code-implement-reviewer code-implementer \
    || block "$rel_path is owned by code-implement-reviewer (current agent: ${agent_type:-main-session})"
  exit 0
fi

if [[ "$artifact_owner" == "rebase-conflict-resolver" ]]; then
  matches_any_agent "$agent_type" rebase-conflict-resolver \
    || block "$rel_path is owned by rebase-conflict-resolver (current agent: ${agent_type:-main-session})"
  exit 0
fi

# ── Unrecognized file written by a phase agent ────────────────────────────
# Fail-open with a loud warning: phase agents can still write misc files
# (e.g., scratch notes, helper scripts) that aren't registered artifacts.
# If this fires unexpectedly, add the pattern to phase_artifact_owner().
case "$agent_type" in
  req-clarifier|ui-outliner|nltp-interviewer|nltp-reviewer|tech-interviewer|\
code-planner|code-plan-review-explorer|code-plan-review-architect|\
code-plan-review-critic|code-implementer|code-implement-reviewer|\
rebase-conflict-resolver)
    printf '[qqq-hooks] warning: %s wrote %s which has no recognized qqq artifact owner. Allowing — if this is intentional, add the pattern to phase_artifact_owner() in qqq-protect-files.sh.\n' \
      "$agent_type" "$rel_path" >&2
    ;;
esac

exit 0
