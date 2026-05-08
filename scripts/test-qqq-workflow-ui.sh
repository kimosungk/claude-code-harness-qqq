#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/qqq-workflow.sh"

REAL_GIT=$(command -v git)
REAL_TMUX=$(command -v tmux)

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

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg (unexpected: $needle)"
}

assert_file_contains() {
  local path="$1" needle="$2" msg="$3" content
  [[ -f "$path" ]] || fail "$msg (missing file: $path)"
  content=$(<"$path")
  assert_contains "$content" "$needle" "$msg"
}

setup_repo() {
  local tmp repo remote
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  remote="$tmp/remote.git"
  "$REAL_GIT" init --bare "$remote" >/dev/null
  "$REAL_GIT" init "$repo" >/dev/null
  "$REAL_GIT" -C "$repo" config user.name "qqq test"
  "$REAL_GIT" -C "$repo" config user.email "qqq@example.com"
  printf 'base\n' >"$repo/README.md"
  "$REAL_GIT" -C "$repo" add README.md
  "$REAL_GIT" -C "$repo" commit -m "init" >/dev/null
  "$REAL_GIT" -C "$repo" branch -M main
  "$REAL_GIT" -C "$repo" remote add origin "$remote"
  "$REAL_GIT" -C "$repo" push -u origin main >/dev/null
  printf '%s\t%s\t%s\n' "$tmp" "$repo" "$remote"
}

setup_repo_with_dev() {
  local setup tmp repo remote
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  "$REAL_GIT" -C "$repo" checkout -b dev >/dev/null
  printf 'dev-base\n' >>"$repo/README.md"
  "$REAL_GIT" -C "$repo" add README.md
  "$REAL_GIT" -C "$repo" commit -m "dev base" >/dev/null
  "$REAL_GIT" -C "$repo" push -u origin dev >/dev/null
  "$REAL_GIT" -C "$repo" checkout main >/dev/null
  printf '%s\t%s\t%s\n' "$tmp" "$repo" "$remote"
}

configure_workspace_vars() {
  local repo="$1"
  export QQQ_WORKS_DIR="$repo/claude-works"
  export QQQ_COMPLETED_DIR="$repo/claude-works-completed"
  export QQQ_LAUNCH_PWD="$repo"
  mkdir -p "$QQQ_WORKS_DIR" "$QQQ_COMPLETED_DIR"
}

with_fzf_queue() {
  local queue_file="$1"
  export QQQ_TEST_FZF_QUEUE_FILE="$queue_file"
}

with_prompt_queue() {
  local queue_file="$1"
  export QQQ_TEST_PROMPT_QUEUE_FILE="$queue_file"
}

clear_test_io() {
  unset QQQ_TEST_FZF_QUEUE_FILE QQQ_TEST_PROMPT_QUEUE_FILE QQQ_TEST_FZF_CAPTURE_FILE
}

setup_tmux_test_env() {
  local tmp="$1" log_file="$2" attach_log="${3:-}"
  local bin_dir="$tmp/test-bin"
  mkdir -p "$bin_dir"
  export QQQ_TEST_TMUX_SOCKET="qqq-test-$$-$(basename "$tmp")"
  export QQQ_FAKE_CLAUDE_LOG="$log_file"
  if [[ -n "$attach_log" ]]; then
    export QQQ_FAKE_TMUX_ATTACH_LOG="$attach_log"
  else
    unset QQQ_FAKE_TMUX_ATTACH_LOG
  fi
  export TMUX=1
  cat >"$bin_dir/tmux" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "attach" && "\${2:-}" == "-t" && -n "\${QQQ_FAKE_TMUX_ATTACH_LOG:-}" ]]; then
  printf 'target=%s\n' "\${3:-}" >>"\$QQQ_FAKE_TMUX_ATTACH_LOG"
  exit 0
fi
exec "$REAL_TMUX" -L "$QQQ_TEST_TMUX_SOCKET" -f /dev/null "\$@"
EOF
  cat >"$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
log_file="${QQQ_FAKE_CLAUDE_LOG:?}"
printf 'agent=%s session=%s args=%s\n' "${QQQ_AGENT:-}" "${QQQ_SESSION_DIR:-}" "$*" >>"$log_file"
exit 0
EOF
  chmod +x "$bin_dir/tmux" "$bin_dir/claude"
  export PATH="$bin_dir:$PATH"
}

teardown_tmux_test_env() {
  tmux_test kill-server >/dev/null 2>&1 || true
  unset QQQ_TEST_TMUX_SOCKET QQQ_FAKE_CLAUDE_LOG QQQ_FAKE_TMUX_ATTACH_LOG TMUX
}

tmux_test() {
  "$REAL_TMUX" -L "$QQQ_TEST_TMUX_SOCKET" -f /dev/null "$@"
}

tmux_active_window_name() {
  tmux_test list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_name}\t#{window_active}' \
    | awk -F'\t' '$2=="1" { print $1; exit }'
}

tmux_active_window_index() {
  tmux_test list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_index}\t#{window_active}' \
    | awk -F'\t' '$2=="1" { print $1; exit }'
}

tmux_window_names() {
  tmux_test list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}'
}

tmux_new_named_window() {
  local win_name="$1" cmd="${2:-exec ${SHELL:-/bin/sh}}"
  tmux_test new-window -d -t "$TMUX_SESSION_NAME:" -n "$win_name" "$cmd" >/dev/null
}

wait_for_file_line_count() {
  local path="$1" expected="$2" count=""
  local _i
  for _i in $(seq 1 50); do
    if [[ -f "$path" ]]; then
      count=$(wc -l <"$path" | tr -d ' ')
      if [[ "$count" -ge "$expected" ]]; then
        return 0
      fi
    fi
    sleep 0.1
  done
  fail "timed out waiting for $path to reach $expected lines"
}

make_bootstrapped_session() {
  local repo="$1" slug="$2" prompt_queue session
  prompt_queue=$(mktemp)
  printf '%s\n' "$slug" >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  session=$(cd "$repo" && create_new_session)
  clear_test_io
  rm -f "$prompt_queue"
  printf '%s' "$session"
}

test_scope_and_repo_action_picker() {
  local queue scope action
  queue=$(mktemp)
  printf 'repo\n' >"$queue"
  with_fzf_queue "$queue"
  scope=$(select_session_scope)
  assert_eq "$scope" "repo" "scope picker should return repo"

  printf 'dev-main-mr\n' >"$queue"
  action=$(select_repo_action)
  assert_eq "$action" "dev-main-mr" "repo action picker should return dev-main-mr"
  clear_test_io
  rm -f "$queue"
}

test_new_session_bootstraps_leader_mode_and_phase_flow() {
  local setup tmp repo remote today prompt_queue session expected_session queue capture suggested action captured_text wt_root
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"
  today=$(date +%Y-%m-%d)

  prompt_queue=$(mktemp)
  printf 'phase1-flow\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  session=$(cd "$repo" && create_new_session)
  clear_test_io
  rm -f "$prompt_queue"

  # New sessions bootstrap in leader-mode by default (commit e72e2ea); the
  # user is expected to pick `worktree-create` as a follow-up action when
  # they want isolation. Worktree-first auto-bootstrap is no longer the
  # design intent.
  expected_session="$QQQ_WORKS_DIR/${today}_phase1-flow"
  assert_eq "$session" "$expected_session" "new session should be created in leader-mode default location"
  [[ -d "$session" ]] || fail "leader-mode session dir should exist"
  [[ ! -d "$repo/.qqq-worktrees/phase1-flow" ]] || fail "linked worktree should not be auto-created in leader-mode bootstrap"

  wt_root=$(qqq_session_dir_worktree "$session")
  assert_eq "$wt_root" "" "leader-mode session should not report a linked worktree root"

  # Phase 0 is the default suggestion for an empty session — register-issue
  # populates phase0-issue.md as shared context for req-clarifier. Phase 0
  # is optional from the user's perspective (they can skip it and create
  # phase1-spec.md directly), but detect_next_phase still nudges toward it
  # as the first action when both files are absent.
  suggested=$(detect_next_phase "$session")
  assert_eq "$suggested" "register-issue" "fresh leader-mode session should start at register-issue (Phase 0)"

  printf '# Issue\n' >"$session/phase0-issue.md"
  suggested=$(detect_next_phase "$session")
  assert_eq "$suggested" "req-clarifier" "phase0 issue should advance the suggestion to req-clarifier"

  printf '# Spec\n' >"$session/phase1-spec.md"
  suggested=$(detect_next_phase "$session")
  assert_eq "$suggested" "tech-interviewer" "phase1 spec should suggest tech-interviewer next"

  printf '# Tech\n' >"$session/phase1-tech-spec.md"
  suggested=$(detect_next_phase "$session")
  assert_eq "$suggested" "code-planner" "phase1 tech spec should flow directly to code-planner"

  printf '# Plan\n' >"$session/phase2-code-plan.md"
  suggested=$(detect_next_phase "$session")
  assert_eq "$suggested" "code-planner" "phase2 plan should stay on code-planner until review loop completes"
  local fingerprint
  fingerprint=$(qqq_sha256_file "$session/phase2-code-plan.md")
  cat >"$session/phase2-review-state.json" <<EOF
{"final_verdict":"OKAY","review_loop_completed":true,"gates":{"explorer":{"last_input_fingerprint":"$fingerprint"}}}
EOF
  suggested=$(detect_next_phase "$session")
  assert_eq "$suggested" "code-implementer" "phase2 review completion should unlock code-implementer"

  queue=$(mktemp)
  capture=$(mktemp)
  printf 'code-planner\n' >"$queue"
  with_fzf_queue "$queue"
  export QQQ_TEST_FZF_CAPTURE_FILE="$capture"
  action=$(select_action "$session" "$suggested")
  assert_eq "$action" "code-planner" "action menu should allow code-planner for fresh leader-mode session"
  captured_text=$(tr '\0' '\n' <"$capture")
  assert_contains "$captured_text" "Phase1 T4 · tech-interviewer" "action menu should include tech-interviewer"
  assert_contains "$captured_text" "Phase2 T1 · code-planner" "action menu should include code-planner"
  # In leader-mode (no live worktree) the menu should expose worktree-create
  # so the user can choose to isolate code changes when ready.
  assert_contains "$captured_text" "Worktree · create" "action menu should expose worktree-create in leader-mode"

  clear_test_io
  rm -f "$queue" "$capture"
  trap - RETURN
  rm -rf "$tmp"
}

test_legacy_session_selection_is_blocked() {
  local setup tmp repo remote session row output sessions
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session="$QQQ_WORKS_DIR/2026-04-29_legacy"
  mkdir -p "$session"

  sessions=$(list_sessions active)
  assert_contains "$sessions" "[legacy-blocked]" "legacy session should remain visible in picker with blocked label"

  row=$(qqq_emit_session_row "$session" "$(date +%s)" active "$repo")
  set +e
  output=$(qqq_assert_session_resumable "$(qqq_tsv_field "$row" 2)" 2>&1)
  set -e
  assert_contains "$output" "cannot be resumed" "legacy picker selection should be blocked"

  if validate_session_path "$session" >/dev/null 2>&1; then
    fail "--session should reject blocked legacy sessions"
  fi

  trap - RETURN
  rm -rf "$tmp"
}

test_repo_action_preview_and_preflight_on_unsynced_local_dev() {
  local setup tmp repo remote preview output
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN

  "$REAL_GIT" -C "$repo" checkout -b dev >/dev/null
  printf 'dev-1\n' >>"$repo/README.md"
  "$REAL_GIT" -C "$repo" add README.md
  "$REAL_GIT" -C "$repo" commit -m "dev 1" >/dev/null
  "$REAL_GIT" -C "$repo" push -u origin dev >/dev/null
  printf 'dev-local-only\n' >>"$repo/README.md"
  "$REAL_GIT" -C "$repo" add README.md
  "$REAL_GIT" -C "$repo" commit -m "dev local only" >/dev/null
  "$REAL_GIT" -C "$repo" checkout main >/dev/null

  preview=$(cd "$repo" && repo_action_preview dev-main-mr)
  assert_contains "$preview" "source of truth: origin/dev" "repo preview should show origin/dev as source of truth"
  assert_contains "$preview" "local dev: ahead" "repo preview should show unsynced local dev"
  assert_contains "$preview" "ready: no" "repo preview should mark MR action unready"

  output=$(cd "$repo" && action_dev_mr_create "$repo" 2>&1 || true)
  assert_contains "$output" "origin/dev is the source of truth" "MR action should block on unsynced local dev"

  trap - RETURN
  rm -rf "$tmp"
}

test_repo_action_targets_main_even_when_origin_head_is_dev() {
  local setup tmp repo remote preview
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN

  "$REAL_GIT" -C "$repo" remote set-head origin dev >/dev/null

  preview=$(cd "$repo" && repo_action_preview dev-main-mr)
  assert_contains "$preview" "action: create dev -> main MR" "repo preview should target main even when origin/HEAD points at dev"
  assert_contains "$preview" "origin/dev ahead of origin/main: 1 commit(s)" "repo preview should compare dev against main"
  assert_not_contains "$preview" "action: create dev -> dev MR" "repo preview should not fall back to origin/HEAD for dev-main MR"

  trap - RETURN
  rm -rf "$tmp"
}

test_worktree_remove_returns_error_on_remote_delete_failure() {
  local setup tmp repo remote session slug branch wt_path prompt_queue wrapper_dir output
  setup=$(setup_repo)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session="$QQQ_WORKS_DIR/2026-04-29_remove-test"
  mkdir -p "$session"
  slug=$(qqq_slug_from_session_dir "$(basename "$session")")
  branch=$(qqq_worktree_branch_for "$slug")
  wt_path=$(qqq_worktree_path_for "$repo" "$slug")
  mkdir -p "$(dirname "$wt_path")"
  "$REAL_GIT" -C "$repo" worktree add -b "$branch" "$wt_path" main >/dev/null
  mkdir -p "$wt_path/claude-works/$(basename "$session")"
  rm -rf "$session"
  session="$wt_path/claude-works/$(basename "$session")"
  "$REAL_GIT" -C "$wt_path" push -u origin "$branch" >/dev/null

  wrapper_dir=$(mktemp -d)
  cat >"$wrapper_dir/git" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"push origin --delete $branch"* ]]; then
  printf 'mock remote delete failure\n' >&2
  exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$wrapper_dir/git"

  prompt_queue=$(mktemp)
  printf 'n\nn\ny\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  local rc
  set +e
  output=$(PATH="$wrapper_dir:$PATH" action_worktree_remove "$session" selective 2>&1)
  rc=$?
  set -e
  assert_contains "$output" "remote delete precheck: best-effort only" "preflight should mention remote delete uncertainty"
  assert_contains "$output" "could not delete remote branch" "remote delete failure should surface"
  (( rc != 0 )) || fail "worktree-remove should return non-zero when remote delete fails"

  clear_test_io
  rm -f "$prompt_queue"
  rm -rf "$wrapper_dir"
  trap - RETURN
  rm -rf "$tmp"
}

test_worktree_merge_archives_bootstrapped_session() {
  local setup tmp repo remote session_name session archived_session prompt_queue merge_state leader_archive
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  trap 'rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session_name="2026-04-29_archive-test"
  session=$(cd "$repo" && qqq_bootstrap_session_worktree "$session_name")
  printf '# Spec\n' >"$session/phase1-spec.md"
  printf '# Tech\n' >"$session/phase1-tech-spec.md"
  printf '# Plan\n' >"$session/phase2-code-plan.md"
  printf 'implemented\n' >"$session/phase3-implement-log.md"

  prompt_queue=$(mktemp)
  printf 'n\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  merge=$(cd "$repo" && action_worktree_merge "$session")
  clear_test_io
  rm -f "$prompt_queue"

  archived_session="$repo/.qqq-worktrees/archive-test/claude-works-completed/$session_name"
  assert_eq "$merge" "$archived_session" "merged session should archive under the worktree completed path"
  [[ -d "$archived_session" ]] || fail "archived worktree session should exist"
  [[ ! -d "$session" ]] || fail "original active worktree session path should be moved to completed"

  merge_state=$(qqq_merge_state_get "$archived_session" status)
  assert_eq "$merge_state" "completed" "archived session should persist completed merge state"
  leader_archive=$(qqq_merge_state_get "$archived_session" leader_archived_session_dir)
  assert_eq "$leader_archive" "$repo/claude-works-completed/$session_name" "merge state should preserve leader archive recovery path"
  trap - RETURN
  rm -rf "$tmp"
}

test_agent_window_preflight_launches_without_existing_agent_windows() {
  local setup tmp repo remote session launch_log win_name log_path old_path old_tmux_session
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "clean-launch")
  launch_log="$tmp/claude-launch.log"
  : >"$launch_log"
  setup_tmux_test_env "$tmp" "$launch_log"
  TMUX_SESSION_NAME="qqq|preflight-clean"

  run_agent "$session" req-clarifier
  wait_for_file_line_count "$launch_log" 1

  win_name="$(basename "$session"):req-clarifier"
  assert_contains "$(tmux_window_names)" "$win_name" "fresh agent launch should create its tmux window"
  log_path="$session/.qqq/log.jsonl"
  assert_file_contains "$log_path" '"event":"agent_window_conflict"' "preflight should be logged"
  assert_file_contains "$log_path" '"mode":"none"' "no-conflict launch should log mode=none"
  assert_file_contains "$log_path" '"action":"launch"' "no-conflict launch should log launch action"
  assert_file_contains "$log_path" '"event":"agent_launch"' "fresh agent launch should still emit agent_launch"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

test_agent_window_preflight_non_duplicate_choices_and_ignores_non_agent_windows() {
  local setup tmp repo remote session launch_log prompt_queue output win_slug req_win other_win old_path old_tmux_session count
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "non-duplicate")
  win_slug=$(qqq_window_slug_from_session_dir "$session")
  req_win="${win_slug}:req-clarifier"
  other_win="${win_slug}:ui-outliner"
  launch_log="$tmp/claude-launch.log"
  : >"$launch_log"
  setup_tmux_test_env "$tmp" "$launch_log"
  TMUX_SESSION_NAME="qqq|preflight-nondup"

  ensure_tmux_session
  tmux_new_named_window "${win_slug}:view-artifacts"
  tmux_new_named_window "${win_slug}:shell"
  run_agent "$session" req-clarifier
  wait_for_file_line_count "$launch_log" 1
  assert_contains "$(tmux_window_names)" "$req_win" "excluded utility windows should not block agent launch"

  tmux_test kill-server >/dev/null 2>&1 || true
  ensure_tmux_session
  tmux_new_named_window "${win_slug}:view-artifacts"
  tmux_new_named_window "$other_win"
  prompt_queue=$(mktemp)
  printf '2\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  output=$(run_agent "$session" req-clarifier 2>&1)
  clear_test_io
  rm -f "$prompt_queue"
  wait_for_file_line_count "$launch_log" 2
  assert_contains "$output" "$other_win" "non-duplicate prompt should list managed agent windows"
  assert_not_contains "$output" "${win_slug}:view-artifacts" "non-duplicate prompt should ignore utility windows"
  assert_contains "$(tmux_window_names)" "$other_win" "keeping existing windows should preserve the other agent window"
  assert_contains "$(tmux_window_names)" "$req_win" "keeping existing windows should still launch the target agent"

  tmux_test kill-server >/dev/null 2>&1 || true
  ensure_tmux_session
  tmux_new_named_window "$other_win"
  prompt_queue=$(mktemp)
  printf '1\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  run_agent "$session" req-clarifier >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  wait_for_file_line_count "$launch_log" 3
  assert_not_contains "$(tmux_window_names)" "$other_win" "kill-all-and-launch should remove existing agent windows"
  assert_contains "$(tmux_window_names)" "$req_win" "kill-all-and-launch should launch the target agent"

  tmux_test kill-server >/dev/null 2>&1 || true
  ensure_tmux_session
  tmux_new_named_window "$other_win"
  prompt_queue=$(mktemp)
  printf '3\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  run_agent "$session" req-clarifier >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  count=$(awk '/^agent=/' "$launch_log" | wc -l | tr -d ' ')
  assert_eq "$count" "3" "cancel should not trigger an extra claude launch"
  assert_contains "$(tmux_window_names)" "$other_win" "cancel should keep the existing agent window"
  assert_not_contains "$(tmux_window_names)" "$req_win" "cancel should not create the target agent window"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

test_agent_window_preflight_duplicate_focus_and_restart_same_role() {
  local setup tmp repo remote session launch_log win_slug target_win old_path old_tmux_session prompt_queue output
  local indices latest_index active_index same_role_count log_path
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "duplicate-role")
  win_slug=$(qqq_window_slug_from_session_dir "$session")
  target_win="${win_slug}:code-planner"
  launch_log="$tmp/claude-launch.log"
  : >"$launch_log"
  setup_tmux_test_env "$tmp" "$launch_log"
  TMUX_SESSION_NAME="qqq|preflight-duplicate"

  ensure_tmux_session
  tmux_new_named_window "$target_win" "sleep 300"
  tmux_new_named_window "$target_win" "sleep 300"
  indices=$(tmux_test list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_index}\t#{window_name}' \
    | awk -F'\t' -v target="$target_win" '$2==target { print $1 }')
  latest_index=$(printf '%s\n' "$indices" | tail -n 1)

  prompt_queue=$(mktemp)
  printf '1\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  output=$(run_agent "$session" code-planner "$session/phase1-spec.md" 2>&1)
  clear_test_io
  rm -f "$prompt_queue"
  active_index=$(tmux_active_window_index)
  assert_eq "$active_index" "$latest_index" "focus-existing should select the highest-index same-role window"
  assert_contains "$output" "$target_win" "duplicate prompt should list the conflicting same-role window"
  [[ ! -s "$launch_log" ]] || fail "focus-existing should not relaunch claude"

  prompt_queue=$(mktemp)
  printf '2\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  run_agent "$session" code-planner "$session/phase1-spec.md" >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  wait_for_file_line_count "$launch_log" 1
  same_role_count=$(tmux_test list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' \
    | awk -v target="$target_win" '$0==target { c++ } END { print c + 0 }')
  assert_eq "$same_role_count" "1" "restart should remove all same-role windows before relaunch"
  log_path="$session/.qqq/log.jsonl"
  assert_file_contains "$log_path" '"action":"focus"' "focus-existing should be logged"
  assert_file_contains "$log_path" '"action":"kill_same_role_and_launch"' "restart should be logged"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

test_agent_window_preflight_focus_existing_attaches_outside_tmux() {
  local setup tmp repo remote session launch_log attach_log win_slug target_win old_path old_tmux_session prompt_queue output
  local indices latest_index active_index saved_tmux
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "duplicate-outside-tmux")
  win_slug=$(qqq_window_slug_from_session_dir "$session")
  target_win="${win_slug}:code-planner"
  launch_log="$tmp/claude-launch.log"
  attach_log="$tmp/tmux-attach.log"
  : >"$launch_log"
  : >"$attach_log"
  setup_tmux_test_env "$tmp" "$launch_log" "$attach_log"
  TMUX_SESSION_NAME="qqq|preflight-outside"

  ensure_tmux_session
  tmux_new_named_window "$target_win" "sleep 300"
  tmux_new_named_window "$target_win" "sleep 300"
  indices=$(tmux_test list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_index}\t#{window_name}' \
    | awk -F'\t' -v target="$target_win" '$2==target { print $1 }')
  latest_index=$(printf '%s\n' "$indices" | tail -n 1)

  prompt_queue=$(mktemp)
  printf '1\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  saved_tmux="${TMUX:-}"
  unset TMUX
  output=$(run_agent "$session" code-planner "$session/phase1-spec.md" 2>&1)
  TMUX="$saved_tmux"
  clear_test_io
  rm -f "$prompt_queue"

  active_index=$(tmux_active_window_index)
  assert_eq "$active_index" "$latest_index" "outside-tmux focus-existing should select the highest-index same-role window"
  assert_contains "$output" "$target_win" "outside-tmux duplicate prompt should list the conflicting same-role window"
  assert_file_contains "$attach_log" "target=$TMUX_SESSION_NAME" "outside-tmux focus-existing should attach to the qqq tmux session"
  [[ ! -s "$launch_log" ]] || fail "outside-tmux focus-existing should not relaunch claude"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

test_agent_window_preflight_kill_paths_survive_tmux_renumbering() {
  local setup tmp repo remote session launch_log win_slug target_win other_win req_win tech_win old_path old_tmux_session prompt_queue
  local same_role_count managed_count
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "renumbered-preflight")
  win_slug=$(qqq_window_slug_from_session_dir "$session")
  target_win="${win_slug}:code-planner"
  other_win="${win_slug}:ui-outliner"
  req_win="${win_slug}:req-clarifier"
  tech_win="${win_slug}:tech-interviewer"
  launch_log="$tmp/claude-launch.log"
  : >"$launch_log"
  setup_tmux_test_env "$tmp" "$launch_log"
  TMUX_SESSION_NAME="qqq|preflight-renumber"

  ensure_tmux_session
  tmux_test set-option -t "$TMUX_SESSION_NAME" renumber-windows on >/dev/null
  tmux_new_named_window "$target_win" "sleep 300"
  tmux_new_named_window "$target_win" "sleep 300"
  tmux_new_named_window "$other_win" "sleep 300"
  prompt_queue=$(mktemp)
  printf '2\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  run_agent "$session" code-planner "$session/phase1-spec.md" >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  wait_for_file_line_count "$launch_log" 1
  same_role_count=$(tmux_test list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' \
    | awk -v target="$target_win" '$0==target { c++ } END { print c + 0 }')
  assert_eq "$same_role_count" "1" "duplicate restart should leave exactly one fresh target window when renumbering is enabled"
  assert_contains "$(tmux_window_names)" "$other_win" "duplicate restart should preserve non-target agent windows when renumbering is enabled"

  tmux_test kill-server >/dev/null 2>&1 || true
  ensure_tmux_session
  tmux_test set-option -t "$TMUX_SESSION_NAME" renumber-windows on >/dev/null
  tmux_new_named_window "$other_win" "sleep 300"
  tmux_new_named_window "$tech_win" "sleep 300"
  tmux_new_named_window "${win_slug}:view-artifacts" "sleep 300"
  prompt_queue=$(mktemp)
  printf '1\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  run_agent "$session" req-clarifier >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  wait_for_file_line_count "$launch_log" 2
  managed_count=$(qqq_list_session_agent_windows "$session" | wc -l | tr -d ' ')
  assert_eq "$managed_count" "1" "kill-all-and-launch should leave exactly one managed agent window when renumbering is enabled"
  assert_contains "$(tmux_window_names)" "$req_win" "kill-all-and-launch should create the fresh target window when renumbering is enabled"
  assert_not_contains "$(tmux_window_names)" "$other_win" "kill-all-and-launch should remove existing managed windows when renumbering is enabled"
  assert_not_contains "$(tmux_window_names)" "$tech_win" "kill-all-and-launch should remove all prior managed windows when renumbering is enabled"
  assert_contains "$(tmux_window_names)" "${win_slug}:view-artifacts" "kill-all-and-launch should continue to ignore excluded windows"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

test_rewind_warning_lists_only_managed_agent_windows() {
  local setup tmp repo remote session queue output win_slug old_path old_tmux_session launch_log
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "rewind-warning")
  launch_log="$tmp/claude-launch.log"
  : >"$launch_log"
  setup_tmux_test_env "$tmp" "$launch_log"
  TMUX_SESSION_NAME="qqq|rewind-warning"

  ensure_tmux_session
  win_slug=$(qqq_window_slug_from_session_dir "$session")
  tmux_new_named_window "${win_slug}:code-planner"
  tmux_new_named_window "${win_slug}:view-artifacts"
  tmux_new_named_window "${win_slug}:shell"
  queue=$(mktemp)
  printf 'cancel\n' >"$queue"
  with_fzf_queue "$queue"
  output=$(rewind_session "$session" 2>&1)
  clear_test_io
  rm -f "$queue"
  assert_contains "$output" "${win_slug}:code-planner" "rewind warning should include managed agent windows"
  assert_not_contains "$output" "${win_slug}:view-artifacts" "rewind warning should ignore utility windows"
  assert_not_contains "$output" "${win_slug}:shell" "rewind warning should ignore shell windows"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

test_rebase_conflict_preflight_uses_same_duplicate_rules() {
  local setup tmp repo remote session wt_path git_dir launch_log win_slug target_win old_path old_tmux_session
  local prompt_queue latest_index active_index same_role_count log_path
  setup=$(setup_repo_with_dev)
  IFS=$'\t' read -r tmp repo remote <<<"$setup"
  old_path="$PATH"
  old_tmux_session="${TMUX_SESSION_NAME:-}"
  trap 'PATH="$old_path"; TMUX_SESSION_NAME="$old_tmux_session"; teardown_tmux_test_env; rm -rf "$tmp"' RETURN
  configure_workspace_vars "$repo"

  session=$(make_bootstrapped_session "$repo" "rebase-preflight")
  wt_path=$(qqq_session_dir_worktree "$session")
  git_dir=$("$REAL_GIT" -C "$wt_path" rev-parse --git-dir)
  [[ "$git_dir" = /* ]] || git_dir="$wt_path/$git_dir"
  mkdir -p "$git_dir/rebase-merge"

  launch_log="$tmp/claude-launch.log"
  : >"$launch_log"
  setup_tmux_test_env "$tmp" "$launch_log"
  TMUX_SESSION_NAME="qqq|rebase-preflight"
  ensure_tmux_session

  win_slug=$(qqq_window_slug_from_session_dir "$session")
  target_win="${win_slug}:rebase-resolver"
  tmux_new_named_window "$target_win" "sleep 300"
  tmux_new_named_window "$target_win" "sleep 300"
  latest_index=$(tmux_test list-windows -t "$TMUX_SESSION_NAME" -F $'#{window_index}\t#{window_name}' \
    | awk -F'\t' -v target="$target_win" '$2==target { idx=$1 } END { print idx }')

  prompt_queue=$(mktemp)
  printf '1\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  action_resolve_rebase_conflict "$session" >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  active_index=$(tmux_active_window_index)
  assert_eq "$active_index" "$latest_index" "rebase focus-existing should select the highest-index existing resolver window"
  [[ ! -s "$launch_log" ]] || fail "rebase focus-existing should not relaunch claude"

  prompt_queue=$(mktemp)
  printf '2\n' >"$prompt_queue"
  with_prompt_queue "$prompt_queue"
  action_resolve_rebase_conflict "$session" >/dev/null
  clear_test_io
  rm -f "$prompt_queue"
  wait_for_file_line_count "$launch_log" 1
  same_role_count=$(tmux_test list-windows -t "$TMUX_SESSION_NAME" -F '#{window_name}' \
    | awk -v target="$target_win" '$0==target { c++ } END { print c + 0 }')
  assert_eq "$same_role_count" "1" "rebase restart should kill all duplicate resolver windows before relaunch"
  log_path="$session/.qqq/log.jsonl"
  assert_file_contains "$log_path" '"target_role":"rebase-resolver"' "rebase preflight should log the resolver role"

  trap - RETURN
  PATH="$old_path"
  TMUX_SESSION_NAME="$old_tmux_session"
  teardown_tmux_test_env
  rm -rf "$tmp"
}

main() {
  test_scope_and_repo_action_picker
  test_new_session_bootstraps_leader_mode_and_phase_flow
  test_legacy_session_selection_is_blocked
  test_repo_action_preview_and_preflight_on_unsynced_local_dev
  test_worktree_remove_returns_error_on_remote_delete_failure
  test_worktree_merge_archives_bootstrapped_session
  test_agent_window_preflight_launches_without_existing_agent_windows
  test_agent_window_preflight_non_duplicate_choices_and_ignores_non_agent_windows
  test_agent_window_preflight_duplicate_focus_and_restart_same_role
  test_agent_window_preflight_focus_existing_attaches_outside_tmux
  test_agent_window_preflight_kill_paths_survive_tmux_renumbering
  test_rewind_warning_lists_only_managed_agent_windows
  test_rebase_conflict_preflight_uses_same_duplicate_rules
  printf 'ok\n'
}

if [[ "${QQQ_TEST_UI_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
