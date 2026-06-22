#!/usr/bin/env bash
# pull-fix.sh — Bridge CodeBeast D1 fix_queue → cc-taskrunner queue.json
#
# Pulls a single approved QUEUED-tier fix from CodeBeast's D1 fix_queue table
# and appends it to queue.json as a pending task. Claims the D1 row
# (status pending → in_progress) with a compare-and-set guard so two runners
# cannot pick up the same fix.
#
# Approval is intentionally manual: a human reviews CodeBeast's
# "AWAITING APPROVAL" comment, then runs this with the fix id.
#
# Usage:
#   scripts/pull-fix.sh --fix-id <uuid>
#   scripts/pull-fix.sh --fix-id <uuid> --dry-run
#
# Required env vars:
#   CLOUDFLARE_API_TOKEN  — CF API token with D1 read/write
#   CF_ACCOUNT_ID         — Cloudflare account id
#   D1_FIX_QUEUE_DB_ID    — D1 database id for the fix_queue DB
#
# Optional:
#   CC_QUEUE_FILE         — override queue.json path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUEUE_FILE="${CC_QUEUE_FILE:-${REPO_DIR}/queue.json}"

# ─── Parse args ──────────────────────────────────────────────
FIX_ID=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-id)  FIX_ID="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

err() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$FIX_ID" ]] || err "--fix-id <uuid> is required"

# ─── Validate env ────────────────────────────────────────────
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || err "CLOUDFLARE_API_TOKEN is not set"
[[ -n "${CF_ACCOUNT_ID:-}" ]]        || err "CF_ACCOUNT_ID is not set"
[[ -n "${D1_FIX_QUEUE_DB_ID:-}" ]]   || err "D1_FIX_QUEUE_DB_ID is not set"

command -v curl >/dev/null 2>&1    || err "curl is required"
command -v python3 >/dev/null 2>&1 || err "python3 is required"

D1_URL="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${D1_FIX_QUEUE_DB_ID}/query"

# d1_query <sql> <json-array-of-params>
# Prints the raw response body to stdout; exits non-zero on HTTP/curl failure.
d1_query() {
  local sql="$1" params="$2" body http_code response

  body=$(python3 -c '
import json, sys
print(json.dumps({"sql": sys.argv[1], "params": json.loads(sys.argv[2])}))
' "$sql" "$params")

  response=$(curl -sS -w $'\n%{http_code}' -X POST "$D1_URL" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$body") || err "D1 request failed (curl)"

  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [[ "$http_code" != "200" ]]; then
    err "D1 request returned HTTP ${http_code}: ${response}"
  fi
  printf '%s' "$response"
}

# ─── 1. Fetch the fix row ────────────────────────────────────
echo "Fetching fix ${FIX_ID} from D1 fix_queue ..." >&2

SELECT_SQL="SELECT * FROM fix_queue WHERE id = ? AND fix_tier = 'QUEUED' AND status = 'pending'"
fetch_resp="$(d1_query "$SELECT_SQL" "$(printf '["%s"]' "$FIX_ID")")"

# Validate response shape + extract the single row as JSON.
ROW_JSON="$(python3 -c '
import json, sys
resp = json.load(sys.stdin)
if not resp.get("success", False):
    errs = resp.get("errors") or [{"message": "unknown error"}]
    sys.stderr.write("D1 query unsuccessful: %s\n" % json.dumps(errs))
    sys.exit(2)
results = resp.get("result") or []
rows = results[0].get("results", []) if results else []
if len(rows) == 0:
    sys.stderr.write("No QUEUED/pending fix found for id %s (already claimed, wrong tier, or nonexistent)\n" % sys.argv[1])
    sys.exit(3)
if len(rows) > 1:
    sys.stderr.write("Expected 1 row, got %d for id %s\n" % (len(rows), sys.argv[1]))
    sys.exit(4)
print(json.dumps(rows[0]))
' "$FIX_ID" <<<"$fetch_resp")" || exit 1

# ─── 2. Dry run: print and exit without mutating anything ────
if $DRY_RUN; then
  echo "[dry-run] Would pull this fix (no D1 or queue.json changes):" >&2
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), indent=2))' "$ROW_JSON"
  exit 0
fi

# ─── 3. Claim the row (compare-and-set) ──────────────────────
echo "Claiming fix ${FIX_ID} (status pending → in_progress) ..." >&2

CLAIM_SQL="UPDATE fix_queue SET status = 'in_progress' WHERE id = ? AND status = 'pending'"
claim_resp="$(d1_query "$CLAIM_SQL" "$(printf '["%s"]' "$FIX_ID")")"

CHANGES="$(python3 -c '
import json, sys
resp = json.load(sys.stdin)
if not resp.get("success", False):
    sys.stderr.write("D1 claim update unsuccessful: %s\n" % json.dumps(resp.get("errors")))
    sys.exit(2)
results = resp.get("result") or []
meta = results[0].get("meta", {}) if results else {}
print(meta.get("changes", 0))
' <<<"$claim_resp")" || exit 1

if [[ "$CHANGES" != "1" ]]; then
  err "Fix ${FIX_ID} already claimed by another runner (rows changed: ${CHANGES})"
fi

# ─── 4. Map D1 row → queue.json task and append ──────────────
init_queue() {
  [[ -f "$QUEUE_FILE" ]] || echo '[]' > "$QUEUE_FILE"
}
init_queue

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 -c '
import json, sys

row = json.loads(sys.argv[1])
queue_file = sys.argv[2]
created_at = sys.argv[3]

fix_id = row["id"]

task = {
    "id": fix_id,
    "title": row.get("title") or f"CodeBeast fix {fix_id[:8]}",
    "repo": row.get("repo") or ".",
    "prompt": row.get("prompt") or "",
    "authority": row.get("authority") or "auto_safe",
    "max_turns": int(row.get("max_turns") or 20),
    "status": "pending",
    "created_at": created_at,
    "origin": "d1_fix_queue",
    "fix_queue_id": fix_id,
}

# Optional pass-through fields for branch base / tracing.
if row.get("origin_branch"):
    task["feature_branch"] = row["origin_branch"]
if row.get("issue_url"):
    task["issue_url"] = row["issue_url"]
if row.get("correlation_id"):
    task["correlation_id"] = row["correlation_id"]

with open(queue_file) as f:
    queue = json.load(f)

if any(t.get("id") == fix_id for t in queue):
    sys.stderr.write(f"Fix {fix_id} already present in queue.json — not appending duplicate.\n")
    sys.exit(5)

queue.append(task)
with open(queue_file, "w") as f:
    json.dump(queue, f, indent=2)

print("Pulled fix %s: %s -> queue.json" % (fix_id, task["title"]))
' "$ROW_JSON" "$QUEUE_FILE" "$CREATED_AT"
