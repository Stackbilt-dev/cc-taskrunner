#!/usr/bin/env bash
# stop-checkpoint.sh — Stop hook for autonomous taskrunner sessions
#
# On natural stop: re-engage Claude if TypeScript errors are found.
# On second fire (stop_hook_active=true): allows stop to prevent infinite loops.
#
# Writes checkpoint to $CC_CHECKPOINT_FILE (set by taskrunner) so the
# taskrunner can include it in retry prompts.
#
# Copyright 2026 Stackbilt LLC — Apache 2.0

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stop_hook_active", False))' 2>/dev/null || echo "False")
LAST_MSG=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_assistant_message","")[:500])' 2>/dev/null || echo "")
CWD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null || echo "")

CHECKPOINT_FILE="${CC_CHECKPOINT_FILE:-}"

# ─── Always capture checkpoint ────────────────────────────────

capture_checkpoint() {
  [[ -n "$CHECKPOINT_FILE" ]] || return 0

  local changed_files=""

  if [[ -n "$CWD" ]] && git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    changed_files=$(git -C "$CWD" diff --name-only 2>/dev/null | head -20)
  fi

  CC_LAST_MSG="$LAST_MSG" CC_CHANGED="$changed_files" CC_CWD="$CWD" python3 - > "$CHECKPOINT_FILE" <<'PY'
import json, os
print(json.dumps({
    "last_message": os.environ.get("CC_LAST_MSG", "")[:500],
    "changed_files": [f for f in os.environ.get("CC_CHANGED", "").split("\n") if f],
    "cwd": os.environ.get("CC_CWD", ""),
}))
PY
}

capture_checkpoint

# ─── If already re-engaged once, let it stop ─────────────────

if [[ "$STOP_HOOK_ACTIVE" == "True" ]]; then
  exit 0
fi

# ─── On natural stop: check if TypeScript errors exist ────────

if [[ -z "$CWD" ]]; then
  exit 0
fi

# Quick typecheck (most common failure mode)
TC_EXIT=0
TC_OUTPUT=""
if [[ -f "$CWD/web/tsconfig.json" ]]; then
  TC_OUTPUT=$(cd "$CWD/web" && npx tsc --noEmit 2>&1 | tail -5)
  TC_EXIT=$?
elif [[ -f "$CWD/tsconfig.json" ]]; then
  TC_OUTPUT=$(cd "$CWD" && npx tsc --noEmit 2>&1 | tail -5)
  TC_EXIT=$?
fi

if [[ $TC_EXIT -ne 0 ]]; then
  # Re-engage: tell Claude to fix type errors before stopping
  TC_SNIPPET=$(echo "$TC_OUTPUT" | head -10 | tr '\n' ' ' | cut -c1-300)
  printf '{"decision":"block","reason":"TypeScript errors detected. Fix before completing:\\n%s"}' "$TC_SNIPPET"
  exit 0
fi

# TypeScript clean — allow stop
exit 0
