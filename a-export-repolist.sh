#!/usr/bin/env bash
set -euo pipefail

# === Config (env overrides) ===
GH_HOST="${GH_HOST:-github.maybank.com}"
CONCURRENCY="${CONCURRENCY:-8}"               # parallel workers
OUT="${OUT:-universal-repos.csv}"             # repo,default_branch,branch
LIMIT_REPOS="${LIMIT_REPOS:-0}"               # 0=all; else first N repos for smoke test
TRACE="${TRACE:-0}"                           # 1=debug tracing

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
REPO_LIST="$TMP_DIR/repos.csv"
PART_DIR="$TMP_DIR/parts"; mkdir -p "$PART_DIR"

echo "[1/3] Fetching repositories visible to this account..." >&2
echo "repo,default_branch" > "$REPO_LIST"
gh api -X GET --paginate "/user/repos" \
  -f per_page=100 \
  -f affiliation=owner,collaborator,organization_member \
  -f visibility=all \
| jq -r '.[]? | select(type=="object") | "\(.full_name),\(.default_branch // "main")"' >> "$REPO_LIST"

if [ ! -s "$REPO_LIST" ]; then
  echo "No repositories found. Check access or network." >&2
  exit 1
fi

# Optional sampling for quick test
if [ "$LIMIT_REPOS" -gt 0 ]; then
  REPO_SAMPLE="$TMP_DIR/repos.sample.csv"
  echo "repo,default_branch" > "$REPO_SAMPLE"
  tail -n +2 "$REPO_LIST" | head -n "$LIMIT_REPOS" >> "$REPO_SAMPLE"
  REPO_LIST="$REPO_SAMPLE"
fi

REPO_COUNT="$(tail -n +2 "$REPO_LIST" | wc -l | awk '{print $1}')"
echo "[2/3] Enumerating branches for $REPO_COUNT repos with CONCURRENCY=$CONCURRENCY ..." >&2

# Header for final output
echo "repo,default_branch,branch" > "$OUT"

# Worker function
list_branches_one() {
  local full="$1" def="$2" part="$3"
  : > "$part"
  echo "  → [$full] listing branches..." >&2
  local branches
  branches="$(
    gh api -X GET --paginate "/repos/${full}/branches" -f per_page=100 2>/dev/null \
    | jq -r '.[]? | select(type=="object") | .name' || true
  )"
  if [ -z "$branches" ]; then
    printf "%s,%s,%s\n" "$full" "$def" "$def" >> "$part"
    echo "    (no branches API/empty; used default=$def)" >&2
  else
    printf "%s\n" "$branches" | awk -v R="$full" -v D="$def" 'NF{print R "," D "," $0}' >> "$part"
    echo "    ($(printf "%s\n" "$branches" | wc -l | awk "{print \$1}") branches)" >&2
  fi
}

# Launch workers with a simple job pool (portable on macOS Bash 3.x)
job_count() { jobs -p | wc -l | awk '{print $1}'; }

# Avoid subshell for the while: use process substitution
while IFS= read -r line || [ -n "$line" ]; do
  IFS=, read -r full def <<EOF
$line
EOF
  part="$PART_DIR/${full//\//__}.csv"

  # throttle
  while [ "$(job_count)" -ge "$CONCURRENCY" ]; do sleep 0.2; done
  list_branches_one "$full" "$def" "$part" &
done < <(tail -n +2 "$REPO_LIST")

wait

echo "[3/3] Merging parts..." >&2
find "$PART_DIR" -type f -name '*.csv' -print0 \
| sort -z \
| while IFS= read -r -d '' f; do cat "$f"; done >> "$OUT"

echo "✅ Catalog ready: $OUT" >&2
