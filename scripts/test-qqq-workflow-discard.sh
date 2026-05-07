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

main() {
  test_leader_session_discard
  test_worktree_discard_keep_remote
  test_worktree_discard_delete_remote
  test_force_preview_and_archive_block
  printf 'ok\n'
}

main "$@"
