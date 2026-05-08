# qqq lib — merge-archive
# Merge-time artifact commit primitives (Stage 4): the helpers
# action_worktree_merge calls just before/after rebasing into the dev
# branch — commit_session_artifacts_if_dirty stages session artifacts
# into a single archive commit, and archive_session_to_completed renames
# claude-works/<slug> to claude-works-completed/<slug> with its own
# commit so finished sessions stop showing up in the picker.
# Consumes qqq_path_join and qqq_slug_from_session_dir from
# worktree-helpers (loaded transitively via action-handlers).

# ---------------------------------------------------------------------------
# Merge-time artifact commit (Stage 4)
# ---------------------------------------------------------------------------

# Commit only the active session artifact tree in the given worktree.
# Excludes .qqq.lock via pathspec. Idempotent — no-op when nothing changed.
# Returns 0 on skip or success; stderr for status lines only.
commit_session_artifacts_if_dirty() {
  local worktree="$1" session_dir="$2"
  [[ -d "$worktree" && -d "$session_dir" ]] || return 0
  local rel="${session_dir#"$worktree"/}"
  # Guard: session_dir must actually be under worktree.
  [[ "$rel" == "$session_dir" ]] && return 0

  # Nothing tracked-changed AND nothing new — skip.
  if git -C "$worktree" diff --quiet HEAD -- "$rel" 2>/dev/null \
     && [[ -z $(git -C "$worktree" ls-files --others --exclude-standard -- "$rel" 2>/dev/null) ]]; then
    return 0
  fi

  git -C "$worktree" add -- "$rel" ":!$rel/.qqq.lock" >/dev/null 2>&1 || true

  # If staging the pathspec yielded nothing (e.g. only .qqq.lock changed), bail.
  if git -C "$worktree" diff --cached --quiet -- "$rel" 2>/dev/null; then
    return 0
  fi

  local slug
  slug=$(qqq_slug_from_session_dir "$session_dir")
  if git -C "$worktree" commit --no-verify -m "qqq: $slug archive session artifacts" >/dev/null; then
    printf '[qqq] auto-committed session artifacts under %s\n' "$rel" >&2
  fi
}

# Rename session dir from <worktree>/<launch-subdir>/claude-works/<date_slug>/ to
# <worktree>/<launch-subdir>/claude-works-completed/<date_slug>/ with a dedicated commit.
# Emits new absolute path on stdout when the move succeeds; empty otherwise.
# Fails fast when the destination already exists.
archive_session_to_completed() {
  local worktree="$1" session_dir="$2"
  [[ -d "$worktree" && -d "$session_dir" ]] || return 0
  local rel_src="${session_dir#"$worktree"/}"
  [[ "$rel_src" == "$session_dir" ]] && return 0  # not inside worktree

  local base slug dest_rel dest_abs rel_parent prefix
  local merge_state_src merge_state_dest merge_state_tmp=""
  local moved_to_dest=no
  base=$(basename "$session_dir")
  slug=$(qqq_slug_from_session_dir "$session_dir")
  rel_parent=$(dirname "$rel_src")
  if [[ "$rel_parent" == "claude-works" ]]; then
    prefix=""
  elif [[ "$rel_parent" == */claude-works ]]; then
    prefix="${rel_parent%/claude-works}"
  else
    printf '[qqq] archive source is not under a claude-works/ tree: %s\n' "$rel_src" >&2
    return 1
  fi
  dest_rel="$(qqq_path_join "$prefix" "claude-works-completed/$base")"
  dest_abs="$worktree/$dest_rel"
  merge_state_src="$session_dir/.qqq/merge-state.json"
  merge_state_dest="$dest_abs/.qqq/merge-state.json"

  # Drop the runtime lock file so the source dir has no untracked leftovers
  # (git mv would otherwise leave .qqq.lock behind in the now-empty source).
  # The lock itself stays held via fd 9 against the inode.
  rm -f "$session_dir/.qqq.lock" 2>/dev/null || true
  if [[ -f "$merge_state_src" ]]; then
    merge_state_tmp=$(mktemp "${TMPDIR:-/tmp}/qqq-merge-state.XXXXXX") || return 1
    if ! mv "$merge_state_src" "$merge_state_tmp" 2>/dev/null; then
      rm -f "$merge_state_tmp" 2>/dev/null || true
      printf '[qqq] failed to preserve merge-state sidecar before archive.\n' >&2
      return 1
    fi
  fi

  mkdir -p "$(dirname "$dest_abs")"

  if [[ -e "$dest_abs" ]]; then
    printf '[qqq] completed archive already exists: %s\n' "$dest_abs" >&2
    printf '[qqq] keep the existing archive, clean it up manually, or change the session slug before retrying.\n' >&2
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      mkdir -p "$(dirname "$merge_state_src")"
      mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
    fi
    return 1
  fi

  if ! git -C "$worktree" mv "$rel_src" "$dest_rel" 2>/dev/null; then
    # Fallback: plain mv + add (source may have had untracked residue).
    if ! mv "$session_dir" "$dest_abs" 2>/dev/null; then
      if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
        mkdir -p "$(dirname "$merge_state_src")"
        mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
      fi
      printf '[qqq] archive mv failed (src=%s, dst=%s)\n' "$session_dir" "$dest_abs" >&2
      return 1
    fi
  fi
  moved_to_dest=yes
  git -C "$worktree" add -A -- "$rel_src" 2>/dev/null || true
  git -C "$worktree" add -- "$dest_rel" 2>/dev/null || true

  if git -C "$worktree" diff --cached --quiet 2>/dev/null; then
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      if [[ -d "$dest_abs" ]]; then
        mkdir -p "$(dirname "$merge_state_dest")"
        mv "$merge_state_tmp" "$merge_state_dest" 2>/dev/null || true
      else
        mkdir -p "$(dirname "$merge_state_src")"
        mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
      fi
    fi
    return 0  # nothing staged — caller treats as no-op, no new path emitted
  fi

  if ! git -C "$worktree" commit --no-verify -m "qqq: $slug archive to completed" >/dev/null; then
    if [[ "$moved_to_dest" == "yes" && -d "$dest_abs" && ! -e "$session_dir" ]]; then
      mkdir -p "$(dirname "$session_dir")"
      mv "$dest_abs" "$session_dir" 2>/dev/null || true
      git -C "$worktree" add -A -- "$rel_src" 2>/dev/null || true
      git -C "$worktree" add -A -- "$dest_rel" 2>/dev/null || true
    fi
    if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
      mkdir -p "$(dirname "$merge_state_src")"
      mv "$merge_state_tmp" "$merge_state_src" 2>/dev/null || true
    fi
    printf '[qqq] archive commit failed.\n' >&2
    return 1
  fi
  if [[ -n "$merge_state_tmp" && -f "$merge_state_tmp" ]]; then
    mkdir -p "$(dirname "$merge_state_dest")"
    mv "$merge_state_tmp" "$merge_state_dest" 2>/dev/null || true
  fi
  printf '[qqq] archived session to %s\n' "$dest_rel" >&2
  printf '%s' "$dest_abs"
}
