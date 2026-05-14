# qqq lib — glab-cache
# A2: per-repo TTL cache of GitLab issue/MR state, built once per
# list_sessions invocation and consulted by qqq_session_picker_label so
# picker rows can inline `#42 opened · MR!17 draft` next to the slug.
# Silent no-op when glab is missing, auth fails, or jq is absent — the
# picker must never break because GitLab metadata could not be fetched.

_QQQ_GLAB_INDEX_TTL=60

qqq_glab_index_path() {
  local leader_repo="$1" slug
  slug=$(qqq_repo_slug_from "$leader_repo")
  printf '%s/qqq-glab-index.%s.%s.json' "${TMPDIR:-/tmp}" "${USER:-anon}" "$slug"
}

# Force a build of the cache. Writes an empty index on any failure so the
# picker still has a file to consult (avoids repeated build attempts when
# glab is broken).
qqq_glab_index_build() {
  local leader_repo="$1"
  [[ -n "$leader_repo" && -d "$leader_repo" ]] || return 0
  local cache_path
  cache_path=$(qqq_glab_index_path "$leader_repo")
  local issues_json="" mrs_json=""
  if command -v glab >/dev/null 2>&1; then
    issues_json=$(cd "$leader_repo" && glab issue list --output json --per-page 100 2>/dev/null)
    mrs_json=$(cd "$leader_repo" && glab mr list --output json --per-page 100 2>/dev/null)
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"issues":{},"mrs":{},"ts":%s}\n' "$(date +%s)" >"$cache_path" 2>/dev/null
    return 0
  fi
  local issues_map mrs_map
  issues_map=$(printf '%s' "${issues_json:-[]}" \
    | jq -c '[.[] | {(.iid|tostring): .state}] | add // {}' 2>/dev/null) \
    || issues_map="{}"
  mrs_map=$(printf '%s' "${mrs_json:-[]}" \
    | jq -c '[.[] | {(.source_branch): {iid:.iid, draft:(.draft // .work_in_progress // false), state:.state}}] | add // {}' 2>/dev/null) \
    || mrs_map="{}"
  printf '{"issues":%s,"mrs":%s,"ts":%s}\n' \
    "${issues_map:-{\}}" "${mrs_map:-{\}}" "$(date +%s)" \
    >"$cache_path" 2>/dev/null || true
}

# TTL-honoring build. Only rebuilds when the cache is missing or older than
# _QQQ_GLAB_INDEX_TTL seconds. Cheap on hot path.
qqq_glab_index_ensure() {
  local leader_repo="$1"
  [[ -n "$leader_repo" ]] || return 0
  local cache_path now mtime
  cache_path=$(qqq_glab_index_path "$leader_repo")
  if [[ -f "$cache_path" ]]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$cache_path" 2>/dev/null || stat -f %m "$cache_path" 2>/dev/null || echo 0)
    if (( now - mtime < _QQQ_GLAB_INDEX_TTL )); then
      return 0
    fi
  fi
  qqq_glab_index_build "$leader_repo"
}

# Lookup helpers. Empty stdout on miss / index unavailable.

qqq_glab_index_lookup_issue() {
  local leader_repo="$1" iid="$2"
  [[ -n "$leader_repo" && -n "$iid" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cache_path
  cache_path=$(qqq_glab_index_path "$leader_repo")
  [[ -f "$cache_path" ]] || return 0
  jq -r --arg iid "$iid" '.issues[$iid] // empty' "$cache_path" 2>/dev/null
}

# Returns "<iid>\t<draft>\t<state>" or empty.
qqq_glab_index_lookup_mr() {
  local leader_repo="$1" branch="$2"
  [[ -n "$leader_repo" && -n "$branch" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cache_path
  cache_path=$(qqq_glab_index_path "$leader_repo")
  [[ -f "$cache_path" ]] || return 0
  jq -r --arg br "$branch" '
    .mrs[$br] as $m
    | if $m == null then empty else "\($m.iid)\t\($m.draft)\t\($m.state)" end
  ' "$cache_path" 2>/dev/null
}

export -f qqq_glab_index_path qqq_glab_index_build qqq_glab_index_ensure \
          qqq_glab_index_lookup_issue qqq_glab_index_lookup_mr
