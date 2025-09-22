# GitTrail: Universal Repo Catalog + Per-User Commit Scanner

Fast, repeatable way to:

1. **Index all repos & branches you can access** on GitHub Enterprise, once.
2. **Scan any user’s commits** (author/committer, optional by email) across that catalog in parallel and export to CSV.

---

## Requirements

* macOS/Linux shell (Bash)
* [`gh` CLI](https://cli.github.com/) (authenticated to your Enterprise host)
* [`jq`](https://stedolan.github.io/jq/) installed
* Access to your GitHub Enterprise host (e.g., `github.maybank.com`)

Authenticate once:

```bash
gh auth login --hostname github.maybank.com
```

---

## Files

* `a-export-repolist.sh` — builds `universal-repos.csv` containing every repo + branch you can access
* `b-get-user-commits.sh` — scans commits for a specific user across the catalog and emits a CSV

---

## Quick Start

### 1) Build the universal catalog (once, or when you want to refresh)

```bash
chmod +x a-export-repolist.sh
CONCURRENCY=8 ./a-export-repolist.sh
# Output: universal-repos.csv  (schema: repo,default_branch,branch)
```

Smoke test with fewer repos first:

```bash
LIMIT_REPOS=20 CONCURRENCY=4 ./a-export-repolist.sh
```

### 2) Scan a user’s commits (parallel, deduped, CSV)

```bash
bash ./b-get-user-commits.sh \
  USER_LOGIN="Iresha-Sanduni" \
  CONCURRENCY=8
# Output: commits_Iresha-Sanduni.csv
```

Smoke test on first 10 rows of the catalog:

```bash
USER_LOGIN="Iresha-Sanduni" LIMIT_ROWS=10 CONCURRENCY=4 bash ./b-get-user-commits.sh
```

---

## What You Get

### `universal-repos.csv`

```
repo,default_branch,branch
OrgA/service-a,main,main
OrgA/service-a,main,release/2025-09
OrgB/lib-x,master,master
...
```

### `commits_<user>.csv`

```
repo,branch,sha,authored_date,author_name,author_email,committed_date,committer_name,committer_email,message
OrgA/service-a,main,abc123...,2025-09-01T10:22:33Z,Jane Doe,jane@org.com,2025-09-01T10:25:02Z,Jane Doe,jane@org.com,Fix NPE in payment flow
...
```

* Deduplicated by `(repo, sha)` so the same commit on multiple branches or role scans (author/committer) appears once.
* Sorted by `repo`, `branch`, then `authored_date`.

---

## Common Options (env vars)

### For `a-export-repolist.sh`

* `CONCURRENCY` — number of parallel workers (default `8`)
* `LIMIT_REPOS` — sample first N repos for a quick test (default `0` = all)
* `OUT` — output path (default `universal-repos.csv`)
* `GH_HOST` — GitHub Enterprise host (default `github.maybank.com`)
* `TRACE=1` — enable debug tracing

Examples:

```bash
CONCURRENCY=12 ./a-export-repolist.sh
LIMIT_REPOS=50 CONCURRENCY=4 ./a-export-repolist.sh
OUT="catalog.csv" ./a-export-repolist.sh
```

### For `b-get-user-commits.sh`

* `USER_LOGIN` (**required**) — target username to match (author/committer)
* `USER_EMAILS` — optional comma-separated emails to also match (covers rebases/cherry-picks or odd identity mappings)
* `SINCE` / `UNTIL` — optional ISO timestamps to restrict time window
  e.g. `SINCE="2025-01-01T00:00:00Z" UNTIL="2025-09-22T23:59:59Z"`
* `CONCURRENCY` — parallel workers (default `8`)
* `LIMIT_ROWS` — scan first N rows from the catalog for a quick test (default `0` = all)
* `CATALOG` — path to the repo catalog (default `universal-repos.csv`)
* `OUT` — output CSV (default `commits_${USER_LOGIN}.csv`)
* `GH_HOST` — GitHub Enterprise host (default `github.maybank.com`)
* `TRACE=1` — enable debug tracing

Examples:

```bash
USER_LOGIN="Fahad" CONCURRENCY=8 bash ./b-get-user-commits.sh
USER_LOGIN="Iresha-Sanduni" LIMIT_ROWS=10 CONCURRENCY=4 bash ./b-get-user-commits.sh
USER_LOGIN="Iresha-Sanduni" SINCE="2025-01-01T00:00:00Z" UNTIL="2025-09-22T23:59:59Z" bash ./b-get-user-commits.sh
USER_LOGIN="Iresha-Sanduni" USER_EMAILS="iresha@maybank.com,iresha@vendor.com" bash ./b-get-user-commits.sh
```

---

## How It Works (short)

* **Catalog build:** calls `GET /user/repos` (affiliation: owner, collaborator, org member) → lists **every** repo you can see, then enumerates **all branches** per repo in parallel. Output is stable CSV used by all scans.
* **Scan:** reads the catalog, then in parallel queries `GET /repos/{repo}/commits?sha={branch}&author=...` and `committer=...` (plus emails if provided). Results are merged, deduped, sorted, and exported to CSV.

---

## Troubleshooting

* **“Not authenticated.”**
  Run: `gh auth login --hostname github.maybank.com`

* **Hangs/stalls during catalog build.**
  Use the versions provided here (no FIFOs), and try a smoke test:
  `TRACE=1 LIMIT_REPOS=10 CONCURRENCY=2 ./a-export-repolist.sh`

* **Command line too long (xargs).**
  This repo doesn’t use `xargs` batching; it uses a macOS-safe job pool.

* **Rate limits / timeouts.**
  Lower `CONCURRENCY`, or narrow with `SINCE/UNTIL` or `LIMIT_ROWS` to test.
  You can also re-run; results are idempotent and deduped.

* **Empty results for a user.**
  Try adding `USER_EMAILS` (comma-separated) to match by email as well as login.

---

## Performance Tips

* Start with `LIMIT_REPOS` (build) or `LIMIT_ROWS` (scan) to validate quickly.
* Use `CONCURRENCY=8..16` on beefier machines; reduce on slower networks.
* Use `SINCE`/`UNTIL` if you only care about a timeframe (cuts API volume).

---

## Security & Access

* You will only see repos/branches your account can access.
* All auth is through `gh` CLI; this script stores only CSV outputs locally.

---

## Maintenance

* Rebuild the catalog when org repos/branches change significantly:

  ```bash
  CONCURRENCY=8 ./a-export-repolist.sh
  ```
* Keep `gh` up to date:

  ```bash
  gh version
  gh extension upgrade --all
  ```

---
