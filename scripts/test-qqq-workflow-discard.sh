#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/qqq-workflow.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  [[ "$actual" == "$expected" ]] || fail "$msg (expected=$expected actual=$actual)"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (missing: $needle)"
}

assert_exists() {
  local path="$1" msg="$2"
  [[ -e "$path" ]] || fail "$msg ($path)"
}

assert_missing() {
  local path="$1" msg="$2"
  [[ ! -e "$path" ]] || fail "$msg ($path)"
}

setup_repo() {
  local tmp repo remote
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  remote="$tmp/remote.git"
  git init --bare "$remote" >/dev/null
  git init "$repo" >/dev/null
  git -C "$repo" config user.name "qqq test"
  git -C "$repo" config user.email "qqq@example.com"
  printf 'base\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "init" >/dev/null
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -u origin main >/dev/null
  printf '%s\t%s\t%s\n' "$tmp" "$repo" "$remote"
}

configure_workspace_vars() {
  local repo="$1"
  export QQQ_WORKS_DIR="$repo/claude-works"
  export QQQ_COMPLETED_DIR="$repo/claude-works-completed"
  export QQQ_LAUNCH_PWD="$repo"
  mkdir -p "$QQQ_WORKS_DIR" "$QQQ_COMPLETED_DIR"
}

make_worktree_session() {
  local repo="$1" session_name="$2" push_remote="${3:-no}"
  local slug branch wt_path session_dir
  slug=$(qqq_slug_from_session_dir "$session_name")
  branch=$(qqq_worktree_branch_for "$slug")
  wt_path=$(qqq_worktree_path_for "$repo" "$slug")
  mkdir -p "$(dirname "$wt_path")"
  git -C "$repo" worktree add -b "$branch" "$wt_path" main >/dev/null
  session_dir="$wt_path/claude-works/$session_name"
  mkdir -p "$session_dir"
  if [[ "$push_remote" == "yes" ]]; then
    git -C "$wt_path" push -u origin "$branch" >/dev/null
  fi
  printf '%s\t%s\t%s\n' "$session_dir" "$wt_path" "$branch"
}

test_leader_session_discard() {
  local setup tmp repo remote
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  local session plan plan_kind force_required impact_summary branch
  session="$QQQ_WORKS_DIR/2026-04-28_leader"
  mkdir -p "$session"
  branch=$(qqq_worktree_branch_for "$(qqq_slug_from_session_dir "$(basename "$session")")")
  git -C "$repo" branch "$branch" main >/dev/null

  plan=$(qqq_session_discard_plan "$session" active)
  plan_kind=$(qqq_tsv_field "$plan" 1)
  force_required=$(qqq_tsv_field "$plan" 2)
  impact_summary=$(qqq_tsv_field "$plan" 14)
  assert_eq "$plan_kind" "session-dir-only" "legacy leader session should discard dir only"
  assert_eq "$force_required" "no" "legacy leader session should not require FORCE"
  assert_eq "$impact_summary" "legacy session dir only" "legacy leader summary should stay session-dir-only"

  qqq_execute_session_discard "$session" active no >/dev/null
  assert_missing "$session" "legacy leader session dir should be removed"
  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "legacy discard should not delete matching local branch: $branch"
  fi
  trap - RETURN
  rm -rf "$tmp"
}

test_worktree_discard_keep_remote() {
  local setup tmp repo remote
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  local made session wt_path branch plan plan_kind remote_branch
  made=$(make_worktree_session "$repo" "2026-04-28_keep-remote" yes)
  IFS=$'\t' read -r session wt_path branch <<<"$made"

  plan=$(qqq_session_discard_plan "$session" active)
  plan_kind=$(qqq_tsv_field "$plan" 1)
  remote_branch=$(qqq_tsv_field "$plan" 10)
  assert_eq "$plan_kind" "full-cleanup" "worktree session should plan full cleanup"
  assert_eq "$remote_branch" "yes" "remote branch should be detected"

  qqq_execute_session_discard "$session" active no >/dev/null
  assert_missing "$session" "worktree session dir should be removed"
  assert_missing "$wt_path" "linked worktree should be removed"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "local branch should be deleted: $branch"
  fi
  if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    fail "remote branch should remain when remote deletion is declined: $branch"
  fi
  trap - RETURN
  rm -rf "$tmp"
}

test_worktree_discard_delete_remote() {
  local setup tmp repo remote
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  local made session wt_path branch
  made=$(make_worktree_session "$repo" "2026-04-28_delete-remote" yes)
  IFS=$'\t' read -r session wt_path branch <<<"$made"

  qqq_execute_session_discard "$session" active yes >/dev/null
  assert_missing "$session" "remote-delete session dir should be removed"
  assert_missing "$wt_path" "remote-delete worktree should be removed"
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    fail "remote branch should be deleted: $branch"
  fi
  trap - RETURN
  rm -rf "$tmp"
}

test_force_preview_and_archive_block() {
  local setup tmp repo remote
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  local locked_session preview plan plan_kind force_required completed_session completed_plan
  locked_session="$QQQ_WORKS_DIR/2026-04-28_locked"
  mkdir -p "$locked_session/.qqq"
  printf '%s\n' "$$" >"$locked_session/.qqq.lock"
  qqq_write_json_file "$locked_session/.qqq/merge-state.json" status push_pending

  plan=$(qqq_session_discard_plan "$locked_session" active)
  plan_kind=$(qqq_tsv_field "$plan" 1)
  force_required=$(qqq_tsv_field "$plan" 2)
  assert_eq "$plan_kind" "session-dir-only" "locked legacy session should still be session-only cleanup"
  assert_eq "$force_required" "yes" "locked recovery session should require FORCE"

  preview=$(session_preview "$locked_session")
  assert_contains "$preview" "status: [legacy-blocked]" "preview should mark legacy sessions as blocked"
  assert_contains "$preview" "discard is allowed, but resume is blocked" "preview should explain legacy discard-only behavior"
  assert_contains "$preview" "lock: present" "preview should show lock status"
  assert_contains "$preview" "recovery: FORCE required" "preview should show recovery warning"
  assert_contains "$preview" "discard: discard only; linked worktree cleanup is never attempted" "preview should show discard-only cleanup for legacy sessions"
  assert_contains "$preview" "discard: FORCE confirmation required" "preview should show FORCE requirement"
  assert_contains "$preview" "Maintenance:" "preview should include maintenance section"

  completed_session="$QQQ_COMPLETED_DIR/2026-04-28_done"
  mkdir -p "$completed_session"
  completed_plan=$(qqq_session_discard_plan "$completed_session" completed)
  plan_kind=$(qqq_tsv_field "$completed_plan" 1)
  assert_eq "$plan_kind" "blocked" "completed archive should be blocked from picker discard"

  if qqq_execute_session_discard "$completed_session" completed no >/dev/null 2>&1; then
    fail "blocked archive discard should fail"
  fi
  assert_exists "$completed_session" "blocked archive session should remain"
  trap - RETURN
  rm -rf "$tmp"
}

# D.1 — empirically verify the PR3 deny list (Item 1 in commit e01f88c).
# Asserts the contract every contributor must preserve: a single source of
# truth, the high-blast-radius positive set, and the intentional exclusions
# that keep ui-verifier (curl / kill / rm -f) functional under bypass mode.
test_pr3_deny_list_contract() {
  local deny
  deny=$(qqq_disallowed_tools)

  # Positive: the 10 entries codex / PR3 commit message both pin down.
  local entry
  for entry in \
    'NotebookEdit' \
    'Bash(git push *)' \
    'Bash(git reset --hard *)' \
    'Bash(git clean *)' \
    'Bash(git branch -D *)' \
    'Bash(git worktree remove *)' \
    'Bash(rm -rf *)' \
    'Bash(sudo *)' \
    'Bash(chown *)' \
    'Bash(chmod -R *)'; do
    assert_contains "$deny" "$entry" "deny list missing required entry"
  done

  # Negative: ui-verifier needs these to clean up its dev server. If any
  # appear here, the agent will be unable to tear down localhost listeners.
  # Note `rm -rf *` is a substring of `rm -f *`, so check for the standalone
  # `rm -f ` token (no trailing -r) by looking for ",Bash(rm -f " or "(rm -f ".
  if [[ "$deny" == *'Bash(rm -f '* && "$deny" != *'Bash(rm -rf '* ]]; then
    fail "deny list must not include rm -f without -r (would block ui-verifier dev-server cleanup)"
  fi
  if [[ "$deny" == *'Bash(curl'* ]]; then
    fail "deny list must not include curl (ui-verifier hits localhost via curl)"
  fi
  if [[ "$deny" == *'Bash(kill'* ]]; then
    fail "deny list must not include kill (ui-verifier reaps its dev server pid)"
  fi

  # DRY: action-handlers.sh defines the function once and references it
  # from exactly two call sites (run_agent + launch_rebase_conflict_
  # resolver). Verify the structural shape, not raw mention count
  # (comments mentioning the symbol would skew a naive grep -c).
  local handlers="$ROOT/scripts/lib/action-handlers.sh"
  local defs uses
  defs=$(grep -c '^qqq_disallowed_tools()' "$handlers" || true)
  # Match the assignment pattern, not bare mentions (the function's own doc
  # comment references $(qqq_disallowed_tools) literally).
  uses=$(grep -cE '^[[:space:]]+[a-z_]+=\$\(qqq_disallowed_tools\)' "$handlers" || true)
  assert_eq "$defs" "1" "qqq_disallowed_tools must be defined exactly once in action-handlers.sh"
  assert_eq "$uses" "2" "qqq_disallowed_tools must be assigned from exactly 2 sites (run_agent + launch_rebase_conflict_resolver)"
}

# B.A3 — empirically verify the Bash arm of the PreToolUse hook. Asserts
# the contract that closes the bypass: shell redirections targeting
# launcher-owned artifacts (phase0-issue.md, .qqq/session.json, .qqq.lock)
# are blocked, while ui-verifier-relevant commands (rm -f scratch, kill
# PID, curl localhost) stay unblocked per the B.A1 contract.
test_ba3_bash_arm_contract() {
  local hook="$ROOT/hooks/qqq-protect-files.sh"
  [[ -x "$hook" ]] || fail "qqq-protect-files.sh missing or not executable"

  # Positive: shell redirection into launcher-owned artifacts must block.
  local rc
  set +e
  printf '%s' '{"tool_input":{"command":"echo iid:42 > /tmp/x/phase0-issue.md"}}' | "$hook" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "2" "Bash arm should block writes to phase0-issue.md (rc must be 2)"

  set +e
  printf '%s' '{"tool_input":{"command":"cat /tmp/x/.qqq/session.json"}}' | "$hook" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "2" "Bash arm should block commands referencing .qqq/session.json"

  set +e
  printf '%s' '{"tool_input":{"command":"echo $$ > /tmp/x/.qqq.lock"}}' | "$hook" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$rc" "2" "Bash arm should block commands referencing .qqq.lock"

  # Negative: ui-verifier-style commands must pass through.
  local cmd
  for cmd in \
    'rm -f /tmp/scratch.txt' \
    'kill -9 12345' \
    'curl -s http://localhost:3000/health' \
    'find /tmp -name "*.tmp" -delete'; do
    set +e
    printf '%s' "{\"tool_input\":{\"command\":\"${cmd}\"}}" | "$hook" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "$rc" "0" "Bash arm should NOT block ui-verifier command: ${cmd}"
  done

  # Matcher contract: the install + validate scripts must agree on
  # Edit|Write|Bash. Drift would silently break either fresh installs
  # (no Bash protection) or CI validation (mismatch reported).
  local installer="$ROOT/scripts/install-qqq-hooks.sh"
  local validator="$ROOT/scripts/validate-qqq-hooks.sh"
  grep -qF '"Edit|Write|Bash"' "$installer" \
    || fail "install-qqq-hooks.sh PreToolUse matcher must be Edit|Write|Bash"
  grep -qF 'matcher:"Edit|Write|Bash"' "$validator" \
    || fail "validate-qqq-hooks.sh PreToolUse matcher must be Edit|Write|Bash"
}

main() {
  test_leader_session_discard
  test_worktree_discard_keep_remote
  test_worktree_discard_delete_remote
  test_force_preview_and_archive_block
  test_pr3_deny_list_contract
  test_ba3_bash_arm_contract
  printf 'ok\n'
}

main "$@"
