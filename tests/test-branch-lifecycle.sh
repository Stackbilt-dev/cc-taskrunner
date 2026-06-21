#!/usr/bin/env bash
# tests/test-branch-lifecycle.sh — Branch ratchet lifecycle tests
#
# Asserts:
#   1. ratchet_enabled_for_task returns true by default (opt-out semantics)
#   2. docs/tests/research/deploy categories are exempt
#   3. When a feature branch exists for a task, the ratchet suppresses
#      auto-branch creation (feature_branch_mode=true)
#   4. When no feature branch exists, auto-branch creation proceeds normally
#
# Run: bash tests/test-branch-lifecycle.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKRUNNER="${SCRIPT_DIR}/../taskrunner.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; echo "        expected: $2"; echo "        actual:   $3"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail "$desc" "$expected" "$actual"; fi
}

assert_exit() {
  local desc="$1" want="$2"; shift 2
  local got=0; "$@" 2>/dev/null || got=$?
  if [[ "$want" == "$got" ]]; then pass "$desc"; else fail "$desc (exit)" "$want" "$got"; fi
}

# ── Source ratchet_enabled_for_task from taskrunner.sh ───────────────────────
# Extract just the function so we don't run the main loop.
eval "$(awk '/^ratchet_enabled_for_task\(\)/,/^}/' "$TASKRUNNER")"

# ── 1. Default opt-out semantics ─────────────────────────────────────────────
echo "=== ratchet_enabled_for_task: opt-out defaults ==="

unset CC_RATCHET CC_DISABLE_RATCHET

assert_exit "empty category → ratchet enabled (default ON)" 0 \
  ratchet_enabled_for_task '{"id":"t1","title":"T","category":""}'

assert_exit "bugfix → ratchet enabled" 0 \
  ratchet_enabled_for_task '{"id":"t2","title":"T","category":"bugfix"}'

assert_exit "refactor → ratchet enabled" 0 \
  ratchet_enabled_for_task '{"id":"t3","title":"T","category":"refactor"}'

assert_exit "feature (unknown) → ratchet enabled" 0 \
  ratchet_enabled_for_task '{"id":"t4","title":"T","category":"feature"}'

assert_exit "docs → ratchet disabled (exempt)" 1 \
  ratchet_enabled_for_task '{"id":"t5","title":"T","category":"docs"}'

assert_exit "tests → ratchet disabled (exempt)" 1 \
  ratchet_enabled_for_task '{"id":"t6","title":"T","category":"tests"}'

assert_exit "research → ratchet disabled (exempt)" 1 \
  ratchet_enabled_for_task '{"id":"t7","title":"T","category":"research"}'

assert_exit "deploy → ratchet disabled (exempt)" 1 \
  ratchet_enabled_for_task '{"id":"t8","title":"T","category":"deploy"}'

assert_exit 'explicit "ratchet":false overrides bugfix default' 1 \
  ratchet_enabled_for_task '{"id":"t9","title":"T","category":"bugfix","ratchet":false}'

assert_exit 'explicit "ratchet":true overrides docs exempt' 0 \
  ratchet_enabled_for_task '{"id":"t10","title":"T","category":"docs","ratchet":true}'

CC_RATCHET=0
assert_exit "CC_RATCHET=0 disables ratchet globally" 1 \
  ratchet_enabled_for_task '{"id":"t11","title":"T","category":"bugfix"}'
unset CC_RATCHET

CC_DISABLE_RATCHET=1
assert_exit "CC_DISABLE_RATCHET=1 disables ratchet globally" 1 \
  ratchet_enabled_for_task '{"id":"t12","title":"T","category":"bugfix"}'
unset CC_DISABLE_RATCHET

echo ""

# ── 2. Feature branch suppression ────────────────────────────────────────────
# Simulate the check that execute_task() performs without running a full
# Claude Code session.  The helper mirrors the ratchet branch-suppression
# logic added in taskrunner.sh.

check_auto_branch_suppressed() {
  local task_json="$1" repo_path="$2"

  local fb
  fb=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("feature_branch",""))' \
       <<< "$task_json" 2>/dev/null || echo "")

  [[ -z "$fb" ]] && { echo "no_suppression"; return 0; }

  if ! ratchet_enabled_for_task "$task_json" 2>/dev/null; then
    echo "ratchet_disabled"
    return 0
  fi

  if git -C "$repo_path" rev-parse --verify "refs/heads/${fb}" >/dev/null 2>&1 || \
     git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/${fb}" 2>/dev/null; then
    echo "suppressed"
  else
    echo "branch_not_found"
  fi
}

echo "=== Feature branch suppression ==="

# Create a temporary git repo with a feature branch
TMPDIR_REPO=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMPDIR_REPO'" EXIT

(
  cd "$TMPDIR_REPO"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "initial" > README.md
  git add README.md
  git commit -q -m "initial"
  git checkout -q -b feature/my-fix
  echo "fix" > fix.txt
  git add fix.txt
  git commit -q -m "fix"
  git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
)

unset CC_RATCHET CC_DISABLE_RATCHET

result=$(check_auto_branch_suppressed \
  '{"id":"t20","title":"T","category":"bugfix","feature_branch":"feature/my-fix"}' \
  "$TMPDIR_REPO")
assert_eq "feature branch exists → auto-branch suppressed" "suppressed" "$result"

result=$(check_auto_branch_suppressed \
  '{"id":"t21","title":"T","category":"bugfix"}' \
  "$TMPDIR_REPO")
assert_eq "no feature_branch field → auto-branch proceeds normally" "no_suppression" "$result"

result=$(check_auto_branch_suppressed \
  '{"id":"t22","title":"T","category":"bugfix","feature_branch":"feature/nonexistent"}' \
  "$TMPDIR_REPO")
assert_eq "feature_branch field but branch absent → auto-branch proceeds" "branch_not_found" "$result"

result=$(check_auto_branch_suppressed \
  '{"id":"t23","title":"T","category":"bugfix","feature_branch":"feature/my-fix","ratchet":false}' \
  "$TMPDIR_REPO")
assert_eq "ratchet disabled → no suppression even if branch exists" "ratchet_disabled" "$result"

result=$(check_auto_branch_suppressed \
  '{"id":"t24","title":"T","category":"docs","feature_branch":"feature/my-fix"}' \
  "$TMPDIR_REPO")
assert_eq "docs category (exempt) + feature_branch → no suppression" "ratchet_disabled" "$result"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
