#!/usr/bin/env bash
# cleanup-branches.sh — Remove orphaned auto/ branches whose tasks are completed
#
# Branches created by cc-taskrunner follow the pattern:
#   auto/{category}/{task-id-prefix}   (current format)
#   auto/{task-id-prefix}              (legacy format)
#
# A branch is considered orphaned when its corresponding task in queue.json
# has status "completed".  Dry-run by default; pass --execute to delete.
#
# Usage:
#   ./scripts/cleanup-branches.sh [options]
#
# Options:
#   --repo  <path>  Git repo to scan (default: current directory)
#   --queue <file>  Path to queue.json (default: ../queue.json relative to this script)
#   --execute       Actually delete branches; omit for dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_FILE="${CC_QUEUE_FILE:-${SCRIPT_DIR}/../queue.json}"
REPO_PATH="$(pwd)"
EXECUTE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO_PATH="$2"; shift 2 ;;
    --queue)   QUEUE_FILE="$2"; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    *)         echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO_PATH="$(cd "$REPO_PATH" && pwd)"

if [[ ! -f "$QUEUE_FILE" ]]; then
  echo "Queue file not found: ${QUEUE_FILE}" >&2
  exit 1
fi

if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository: ${REPO_PATH}" >&2
  exit 1
fi

# Collect 8-char prefixes of completed tasks
completed_prefixes=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    queue = json.load(f)
for t in queue:
    if t.get("status") == "completed":
        print(t["id"][:8])
' "$QUEUE_FILE")

if [[ -z "$completed_prefixes" ]]; then
  echo "No completed tasks in ${QUEUE_FILE}."
  exit 0
fi

echo "Completed task prefixes:"
while IFS= read -r prefix; do
  echo "  ${prefix}"
done <<< "$completed_prefixes"
echo ""

# Fetch to get current remote branch state
git -C "$REPO_PATH" fetch origin --prune --quiet 2>/dev/null || true

# Enumerate all auto/ branches (local + remote, deduplicated)
local_branches=$(git -C "$REPO_PATH" branch --list 'auto/*' 2>/dev/null | sed 's/^[* ]*//' || true)
remote_branches=$(git -C "$REPO_PATH" branch -r --list 'origin/auto/*' 2>/dev/null | sed 's|^[* ]*origin/||' || true)
all_branches=$(printf "%s\n%s" "$local_branches" "$remote_branches" | sort -u | grep -v '^$' || true)

if [[ -z "$all_branches" ]]; then
  echo "No auto/ branches found in ${REPO_PATH}."
  exit 0
fi

orphan_count=0

while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue

  # Extract the task prefix from branch name.
  # Handles both auto/{task-id} and auto/{category}/{task-id}.
  branch_tail="${branch##*/}"   # last path segment = task-id prefix

  matched=false
  while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    if [[ "$branch_tail" == "$prefix" ]]; then
      matched=true
      break
    fi
  done <<< "$completed_prefixes"

  if $matched; then
    orphan_count=$((orphan_count + 1))
    if $EXECUTE; then
      echo "  [DELETE] ${branch}"
      if git -C "$REPO_PATH" rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1; then
        git -C "$REPO_PATH" branch -d "$branch" 2>/dev/null || \
          git -C "$REPO_PATH" branch -D "$branch" 2>/dev/null || true
      fi
      if git -C "$REPO_PATH" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
        git -C "$REPO_PATH" push origin --delete "$branch" 2>/dev/null || true
      fi
    else
      echo "  [DRY RUN] Would delete ${branch} (task ${branch_tail} completed)"
    fi
  else
    echo "  [KEEP]    ${branch}"
  fi
done <<< "$all_branches"

echo ""
if [[ $orphan_count -gt 0 ]]; then
  if $EXECUTE; then
    echo "Deleted ${orphan_count} orphan branch(es)."
  else
    echo "${orphan_count} orphan branch(es) to clean up. Re-run with --execute to delete."
  fi
else
  echo "No orphan branches found."
fi
