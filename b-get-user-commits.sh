#!/usr/bin/env bash
set -euo pipefail

# ===== Config (env overrides) =====
GH_HOST="${GH_HOST:-github.maybank.com}"
CATALOG="${CATALOG:-universal-repos.csv}"     # repo,default_branch,branch
USER_LOGIN="${USER_LOGIN:-}"                  # required (e.g., Iresha-Sanduni)
USER_EMAILS="${USER_EMAILS:-}"                # optional: comma-separated emails
SINCE="${SINCE:-}"                            # optional ISO, e.g. 2025-01-01T00:00:00Z
UNTIL="${UNTIL:-}"                            # optional ISO
CONCURRENCY="${CONCURRENCY:-8}"               # workers
LIMIT_ROWS="${LIMIT_ROWS:-0}"                 # 0=all; else first N rows after header
TRACE="${TRACE:-0}"                           # 1=debug

OUT="${OUT:-commits_${USER_LOGIN}.csv}"

[ -n "${USER_LOGIN}" ] || { echo "Set USER_LOGIN"; exit 1; }
[ -s "${CATALOG}" ] || { echo "Missing ${CATALOG} — run build_catalog first."; exit 1; }
[ "$TRACE" = "1" ] && set -x
export GH_HOST

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need gh
need jq

if ! gh auth status -h "$GH_HOST" >/dev/null 2>&1; then
  echo "Not authenticated. Run: gh auth login --hostname $GH_HOST" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
TMP_JSON="$TMP_DIR/all.jsonl"; : > "$TMP_JSON"

# Build work queue (optionally sample)
QUEUE="$TMP_DIR/queue.csv"
if [ "$LIMIT_ROWS" -gt 0 ]; then
  tail -n +2 "$CATALOG" | head -n "$LIMIT_ROWS" > "$QUEUE"
else
  tail -n +2 "$CATALOG" > "$QUEUE"
fi

ROWS="$(wc -l < "$QUEUE" | awk '{print $1}')"
echo "[scan] Target=$USER_LOGIN | Rows=$ROWS | CONCURRENCY=$CONCURRENCY" >&2

# ---- helpers ----
fetch_role() {
  # fetch_role <repo> <branch> <role> <value>
  local repo="$1" br="$2" role="$3" val="$4"
  local args=(-X GET --paginate "/repos/${repo}/commits" -f per_page=100 -f sha="$br" -f "$role=$val")
  [ -n "$SINCE" ] && args+=(-f "since=$SINCE")
  [ -n "$UNTIL" ] && args+=(-f "until=$UNTIL")
  gh api "${args[@]}" \
  | jq -c --arg repo "$repo" --arg br "$br" \
      '.[]? | select(type=="object") | {repo:$repo, branch:$br, sha:.sha, commit:.commit}'
}

scan_one() {
  local repo="$1" def="$2" br="$3"
  local tmp="$TMP_DIR/${repo//\//__}__${br//\//__}.jsonl"
  : > "$tmp"

  echo "  → [$repo@$br] scanning..." >&2

  # by login
  fetch_role "$repo" "$br" author    "$USER_LOGIN" >> "$tmp" || true
  fetch_role "$repo" "$br" committer "$USER_LOGIN" >> "$tmp" || true

  # by emails (optional)
  if [ -n "$USER_EMAILS" ]; then
    IFS=, read -ra emails <<< "$USER_EMAILS"
    for em in "${emails[@]}"; do
      em="${em// /}"
      [ -z "$em" ] && continue
      fetch_role "$repo" "$br" author    "$em" >> "$tmp" || true
      fetch_role "$repo" "$br" committer "$em" >> "$tmp" || true
    done
  fi

  cat "$tmp"
}

# ---- job pool (macOS-safe) ----
job_count(){ jobs -p | wc -l | awk '{print $1}'; }

# Header for final CSV
echo "[scan] Fetching commits..." >&2
while IFS=, read -r repo def br || [ -n "$repo" ]; do
  # throttle
  while [ "$(job_count)" -ge "$CONCURRENCY" ]; do sleep 0.2; done
  (
    scan_one "$repo" "$def" "$br"
  ) >> "$TMP_JSON" &
done < "$QUEUE"
wait

echo "[scan] Rendering CSV..." >&2
jq -s -r '
  ["repo","branch","sha",
   "authored_date","author_name","author_email",
   "committed_date","committer_name","committer_email","message"],
  (
    .
    | unique_by(.repo + ":" + .sha)
    | sort_by(.repo, .branch, (.commit.author.date // ""))
    | map([
        .repo,
        .branch,
        .sha,
        (.commit.author.date // ""),
        (.commit.author.name // ""),
        (.commit.author.email // ""),
        (.commit.committer.date // ""),
        (.commit.committer.name // ""),
        (.commit.committer.email // ""),
        ((.commit.message // "") | gsub("\r\n|\n|\r"; " "))
      ])
    | .[]
  ) | @csv
' "$TMP_JSON" > "$OUT"

echo "✅ Done. Wrote: $OUT" >&2
