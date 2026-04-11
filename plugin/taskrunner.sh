#!/usr/bin/env bash
# cc-taskrunner — Autonomous task queue for Claude Code
#
# Plugin-compatible version. Executes tasks from a local queue file using
# headless Claude Code sessions with safety hooks, branch-per-task isolation,
# and automatic PR creation.
#
# Copyright 2026 Stackbilt LLC
# Licensed under Apache License 2.0
#
# Usage:
#   ./taskrunner.sh                    # Run until queue empty
#   ./taskrunner.sh --max 5            # Run at most 5 tasks
#   ./taskrunner.sh --loop             # Loop forever (poll every 60s)
#   ./taskrunner.sh --dry-run          # Show what would run without executing
#   ./taskrunner.sh add "Fix the bug"  # Add a task to the queue

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_FILE="${CC_QUEUE_FILE:-$(pwd)/queue.json}"
SAFETY_DIR="${SCRIPT_DIR}/safety"
HOOKS_SETTINGS=""
POLL_INTERVAL="${CC_POLL_INTERVAL:-60}"
MAX_TASKS="${CC_MAX_TASKS:-0}"  # 0 = unlimited
MAX_TURNS="${CC_MAX_TURNS:-25}"
REPOS_DIR="${CC_REPOS_DIR:-}"  # Base directory for repo lookups
DRY_RUN=false
LOOP_MODE=false
TASKS_RUN=0

# ─── Repo aliases ───────────────────────────────────────────
# Alias file: one "alias=directory" per line (e.g. smart_revenue_recovery=smart_revenue_recovery_adf)
declare -A REPO_ALIASES
if [[ -f "${CC_REPO_ALIASES:-${SCRIPT_DIR}/repo-aliases.conf}" ]]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" = "#"* ]] && continue
    REPO_ALIASES["${key// /}"]="${val// /}"
  done < "${CC_REPO_ALIASES:-${SCRIPT_DIR}/repo-aliases.conf}"
fi

# ─── Parse args ──────────────────────────────────────────────

ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)     MAX_TASKS="$2"; shift 2 ;;
    --loop)    LOOP_MODE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --turns)   MAX_TURNS="$2"; shift 2 ;;
    add)       ACTION="add"; shift; break ;;
    list)      ACTION="list"; shift ;;
    *)         echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─── Helpers ─────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# ─── Project fingerprint (optional) ──────────────────────────
# Calls `charter surface --markdown` on the target repo to produce a
# compact API-surface map (routes + schema). Injected into the mission
# brief so Claude Code doesn't need to spend turns exploring the layout.
# Gracefully degrades to empty output if charter is unavailable.
build_fingerprint() {
  local repo_path="$1"
  local disabled="${CC_DISABLE_FINGERPRINT:-0}"
  if [[ "$disabled" = "1" ]]; then return 0; fi
  if ! command -v charter >/dev/null 2>&1; then return 0; fi
  local fp_timeout="${CC_FINGERPRINT_TIMEOUT:-60}"
  local output
  output=$(timeout "$fp_timeout" charter surface --root "$repo_path" --markdown 2>/dev/null || true)
  if [[ -z "$output" ]]; then return 0; fi
  echo "$output" | head -n 80
}

# ─── Blast radius preflight (optional) ──────────────────────
# Runs `charter blast` on files referenced by the task prompt. Severity
# ladder: low (0-4) / medium (5-19) / high (20-49) / critical (50+).
# Used as a gate — auto_safe tasks with critical blast are refused.
#
# Env knobs: CC_DISABLE_BLAST, CC_BLAST_WARN, CC_BLAST_BLOCK, CC_BLAST_TIMEOUT
compute_blast_radius() {
  local prompt="$1" repo_path="$2"
  local disabled="${CC_DISABLE_BLAST:-0}"
  if [[ "$disabled" = "1" ]]; then return 0; fi
  if ! command -v charter >/dev/null 2>&1; then return 0; fi
  if [[ ! -d "$repo_path" ]]; then return 0; fi

  local files
  files=$(echo "$prompt" | grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|mjs|cjs)' | sort -u)
  if [[ -z "$files" ]]; then return 0; fi

  local seed_args=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -f "${repo_path}/${f}" ]]; then seed_args+=("$f"); fi
  done <<< "$files"
  if [[ ${#seed_args[@]} -eq 0 ]]; then return 0; fi
  if [[ ${#seed_args[@]} -gt 10 ]]; then seed_args=("${seed_args[@]:0:10}"); fi

  local blast_timeout="${CC_BLAST_TIMEOUT:-60}"
  local blast_json
  blast_json=$(cd "$repo_path" && timeout "$blast_timeout" charter blast "${seed_args[@]}" --format json 2>/dev/null || true)
  if [[ -z "$blast_json" ]]; then return 0; fi

  BLAST_RAW="$blast_json" BLAST_WARN="${CC_BLAST_WARN:-20}" BLAST_BLOCK="${CC_BLAST_BLOCK:-50}" python3 -c '
import json, os, sys
try: d = json.loads(os.environ["BLAST_RAW"])
except Exception: sys.exit(0)
warn = int(os.environ.get("BLAST_WARN", "20"))
block = int(os.environ.get("BLAST_BLOCK", "50"))
affected = int(d.get("summary", {}).get("totalAffected", 0))
seeds = d.get("seeds", []) or []
hot_files = d.get("hotFiles", []) or []
if affected >= block: severity = "critical"
elif affected >= warn: severity = "high"
elif affected >= 5: severity = "medium"
else: severity = "low"
hot_set = {h.get("file") for h in hot_files[:20]}
print(json.dumps({"seeds": seeds, "affected": affected, "severity": severity, "hot_file": any(s in hot_set for s in seeds), "top_hot_files": hot_files[:5]}))
'
}

render_blast_warning() {
  local blast_json="$1"
  [[ -z "$blast_json" ]] && return 0
  BLAST="$blast_json" python3 -c '
import json, os, sys
try: b = json.loads(os.environ["BLAST"])
except Exception: sys.exit(0)
sev = b.get("severity", "")
if sev not in ("high", "critical"): sys.exit(0)
affected = b.get("affected", 0)
seed_list = ", ".join(b.get("seeds", []))
lines = ["", "## Blast Radius Warning", f"- Severity: **{sev.upper()}** — {affected} files affected", f"- Seed files: {seed_list}"]
if b.get("hot_file"):
    lines.append("- One or more seeds are in the top 20 most-imported files (architectural hub)")
lines.append("- Treat this as CROSS_CUTTING: review carefully before merging")
print("\n".join(lines))
'
}

# ─── Ratchet mode (#16) ─────────────────────────────────────
# Measure-before-after validation. See taskrunner.sh for the full doc —
# this is the parallel plugin copy. Keep them in sync.

ratchet_enabled_for_task() {
  local task_json="$1"
  if [[ "${CC_DISABLE_RATCHET:-0}" = "1" ]]; then return 1; fi
  if [[ "${CC_RATCHET:-}" = "0" ]]; then return 1; fi
  if [[ "${CC_RATCHET:-}" = "1" ]]; then return 0; fi
  local explicit category
  explicit=$(echo "$task_json" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("ratchet"); print("" if v is None else str(v).lower())' 2>/dev/null)
  category=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("category", ""))' 2>/dev/null)
  if [[ "$explicit" = "true" ]]; then return 0; fi
  if [[ "$explicit" = "false" ]]; then return 1; fi
  case "$category" in
    refactor|bugfix) return 0 ;;
    docs|tests|research|deploy) return 1 ;;
    *) return 1 ;;
  esac
}

ratchet_snapshot() {
  local repo_path="$1" label="$2"
  local timeout_secs="${CC_RATCHET_TIMEOUT:-180}"
  local tc_status="skip" test_status="skip"
  if [[ -f "${repo_path}/package.json" ]] && command -v python3 >/dev/null 2>&1; then
    local has_typecheck has_test
    has_typecheck=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("1" if "typecheck" in d.get("scripts", {}) else "0")' "${repo_path}/package.json" 2>/dev/null || echo 0)
    has_test=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("1" if "test" in d.get("scripts", {}) else "0")' "${repo_path}/package.json" 2>/dev/null || echo 0)
    if [[ "$has_typecheck" = "1" ]]; then
      if ( cd "$repo_path" && timeout "$timeout_secs" npm run typecheck >/dev/null 2>&1 ); then
        tc_status="pass"
      else
        tc_status="fail"
      fi
    fi
    if [[ "$has_test" = "1" ]]; then
      if ( cd "$repo_path" && timeout "$timeout_secs" npm test >/dev/null 2>&1 ); then
        test_status="pass"
      else
        test_status="fail"
      fi
    fi
  fi
  printf '{"label":"%s","typecheck":"%s","test":"%s"}' "$label" "$tc_status" "$test_status"
}

ratchet_decision() {
  local baseline="$1" post="$2"
  local bt pt bx px
  bt=$(echo "$baseline" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("typecheck","skip"))' 2>/dev/null || echo skip)
  pt=$(echo "$post"     | python3 -c 'import json,sys; print(json.load(sys.stdin).get("typecheck","skip"))' 2>/dev/null || echo skip)
  bx=$(echo "$baseline" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("test","skip"))'      2>/dev/null || echo skip)
  px=$(echo "$post"     | python3 -c 'import json,sys; print(json.load(sys.stdin).get("test","skip"))'      2>/dev/null || echo skip)
  local reverts=()
  if [[ "$bt" = "pass" && "$pt" = "fail" ]]; then
    reverts+=("typecheck regression (pass → fail)")
  fi
  if [[ "$bx" = "pass" && "$px" = "fail" ]]; then
    reverts+=("test regression (pass → fail)")
  fi
  if [[ ${#reverts[@]} -gt 0 ]]; then
    local reason
    reason=$(IFS=', '; echo "${reverts[*]}")
    echo "revert: $reason"
    return 1
  fi
  echo "keep: baseline=tc:${bt},test:${bx} post=tc:${pt},test:${px}"
  return 0
}

# ─── Queue management ───────────────────────────────────────

init_queue() {
  if [[ ! -f "$QUEUE_FILE" ]]; then
    echo '[]' > "$QUEUE_FILE"
  fi
}

add_task() {
  local title="$1"
  local repo="${2:-.}"
  local prompt="${3:-$title}"
  local authority="${4:-auto_safe}"
  local max_turns="${5:-$MAX_TURNS}"

  init_queue

  local task_id
  task_id=$(python3 -c 'import uuid; print(str(uuid.uuid4()))')

  python3 -c "
import json, sys

task = {
    'id': '$task_id',
    'title': sys.argv[1],
    'repo': sys.argv[2],
    'prompt': sys.argv[3],
    'authority': '$authority',
    'max_turns': int('$max_turns'),
    'status': 'pending',
    'created_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}

with open('$QUEUE_FILE', 'r') as f:
    queue = json.load(f)
queue.append(task)
with open('$QUEUE_FILE', 'w') as f:
    json.dump(queue, f, indent=2)

print(f'Added task {task[\"id\"][:8]}: {task[\"title\"]}')
" "$title" "$repo" "$prompt"
}

list_tasks() {
  init_queue
  python3 -c "
import json
with open('$QUEUE_FILE') as f:
    queue = json.load(f)
if not queue:
    print('Queue is empty.')
else:
    for t in queue:
        status = t.get('status', 'pending')
        symbol = {'pending': '○', 'running': '▶', 'completed': '✓', 'failed': '✗', 'cancelled': '⊘'}.get(status, '?')
        print(f'{symbol} {t[\"id\"][:8]}  {status:10}  {t[\"title\"][:60]}')
"
}

fetch_next_task() {
  init_queue
  python3 -c "
import json, re

with open('$QUEUE_FILE') as f:
    queue = json.load(f)

def extract_issue_refs(title):
    \"\"\"Extract issue references like [Issue #123] or #123 from a task title.\"\"\"
    refs = set()
    # Match [Issue #N] pattern (case-insensitive)
    for m in re.finditer(r'\[Issue\s+#(\d+)\]', title, re.IGNORECASE):
        refs.add(int(m.group(1)))
    return refs

# Collect issue refs from running and recently completed tasks
active_issue_refs = set()
for t in queue:
    if t.get('status') in ('running', 'completed'):
        active_issue_refs.update(extract_issue_refs(t.get('title', '')))

# Find first pending task that doesn't duplicate an active issue
for t in queue:
    if t.get('status') != 'pending':
        continue
    task_refs = extract_issue_refs(t.get('title', ''))
    if task_refs and task_refs & active_issue_refs:
        # Duplicate detected — mark as cancelled
        t['status'] = 'cancelled'
        t['result'] = 'Skipped: duplicate of running/completed task for issue #' + ', #'.join(str(r) for r in sorted(task_refs & active_issue_refs))
        with open('$QUEUE_FILE', 'w') as f:
            json.dump(queue, f, indent=2)
        import sys
        print(f'[dedup] Skipping task {t[\"id\"][:8]}: duplicate issue ref', file=sys.stderr)
        continue
    print(json.dumps(t))
    break
else:
    print('')
"
}

update_task_status() {
  local task_id="$1" status="$2" result="${3:-}"
  python3 -c "
import json, sys
with open('$QUEUE_FILE', 'r') as f:
    queue = json.load(f)
for t in queue:
    if t['id'] == sys.argv[1]:
        t['status'] = sys.argv[2]
        if sys.argv[3]:
            t['result'] = sys.argv[3][:4000]
        break
with open('$QUEUE_FILE', 'w') as f:
    json.dump(queue, f, indent=2)
" "$task_id" "$status" "$result"
}

# ─── Generate hooks settings ────────────────────────────────

ensure_hooks_settings() {
  HOOKS_SETTINGS=$(mktemp /tmp/cc-hooks-XXXXXX.json)

  cat > "$HOOKS_SETTINGS" <<SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${SAFETY_DIR}/block-interactive.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${SAFETY_DIR}/safety-gate.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${SAFETY_DIR}/syntax-check.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
}

# ─── Build Claude command ────────────────────────────────────

build_claude_cmd() {
  local prompt="$1" max_turns="$2"

  local cmd=(
    claude
    -p "$prompt"
    --dangerously-skip-permissions
    --output-format json
    --max-turns "$max_turns"
    --settings "$HOOKS_SETTINGS"
  )

  printf '%q ' "${cmd[@]}"
}

# ─── Execute single task ────────────────────────────────────

execute_task() {
  local task_json="$1"

  local task_id title repo prompt max_turns authority
  task_id=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  title=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')
  repo=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("repo", "."))')
  prompt=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["prompt"])')
  max_turns=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("max_turns", 25))' 2>/dev/null)
  authority=$(echo "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authority", "auto_safe"))' 2>/dev/null)

  log "┌─ Task: ${title}"
  log "│  ID:   ${task_id:0:8}"
  log "│  Repo: ${repo}"
  log "│  Turns: ${max_turns}"

  if $DRY_RUN; then
    log "└─ [DRY RUN] Would execute. Skipping."
    return 0
  fi

  # Resolve repo path (supports aliases and CC_REPOS_DIR)
  local repo_path resolved_name
  resolved_name="${REPO_ALIASES[$repo]:-$repo}"
  if [[ "$resolved_name" != "$repo" ]]; then
    log "│  Alias: ${repo} → ${resolved_name}"
  fi

  if [[ "$resolved_name" == "." ]]; then
    repo_path="$(pwd)"
  elif [[ -d "$resolved_name" ]]; then
    repo_path="$(cd "$resolved_name" && pwd)"
  elif [[ -n "$REPOS_DIR" && -d "${REPOS_DIR}/${resolved_name}" ]]; then
    repo_path="$(cd "${REPOS_DIR}/${resolved_name}" && pwd)"
  elif [[ -n "$REPOS_DIR" && -d "${REPOS_DIR}/${repo}" ]]; then
    repo_path="$(cd "${REPOS_DIR}/${repo}" && pwd)"
  else
    err "Repo not found: ${repo}${resolved_name:+ (resolved: ${resolved_name})}"
    update_task_status "$task_id" "failed" "Repo not found: ${repo}"
    return 1
  fi

  # Mark as running
  update_task_status "$task_id" "running"

  # ─── Branch lifecycle ─────────────────────────────────────
  local branch=""
  local use_branch=false
  local stashed=false
  # Ratchet state — initialized up front so the post-validation block
  # can reference them on paths that skip branch creation entirely.
  local RATCHET_ENABLED=false
  local RATCHET_BASELINE=""
  cd "$repo_path"

  # Non-operator tasks get their own branch
  if [[ "$authority" != "operator" ]]; then
    use_branch=true
    branch="auto/${task_id:0:8}"

    # Stash uncommitted TRACKED changes to protect live work.
    # Only stashes real tracked diffs — untracked files alone are usually
    # noise (telemetry, build artifacts) and produce empty stashes that
    # accumulate indefinitely. See #19 for full bug report.
    local has_tracked_dirty=false
    if ! git diff --quiet 2>/dev/null; then has_tracked_dirty=true; fi
    if ! git diff --cached --quiet 2>/dev/null; then has_tracked_dirty=true; fi

    if $has_tracked_dirty; then
      if git stash push -m "cc-taskrunner:${task_id:0:8}" 2>/dev/null; then
        # Verify the stash captured content (drop if empty, race guard)
        if ! git diff stash@{0}^1 stash@{0} --quiet 2>/dev/null; then
          stashed=true
          log "│  Stashed uncommitted tracked changes"
        else
          git stash drop stash@{0} 2>/dev/null || true
          log "│  Stash was empty after push — dropped"
        fi
      fi
    fi

    # Start from main
    git checkout main 2>/dev/null || git checkout master 2>/dev/null
    git pull --ff-only 2>/dev/null || true

    # ── Ratchet baseline capture (#16) ────────────────────────
    if ratchet_enabled_for_task "$task_json"; then
      RATCHET_ENABLED=true
      log "│  Ratchet: capturing baseline on main…"
      RATCHET_BASELINE="$(ratchet_snapshot "$repo_path" baseline)"
      log "│  Ratchet baseline: ${RATCHET_BASELINE}"
    fi

    # Create or reset task branch
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
      git checkout "$branch"
      git reset --hard main 2>/dev/null
    else
      git checkout -b "$branch"
    fi
    log "│  Branch: ${branch}"
  fi

  # Generate project fingerprint (routes + schema) to seed Claude's context
  local fingerprint
  fingerprint="$(build_fingerprint "$repo_path")"
  local fingerprint_section=""
  if [[ -n "$fingerprint" ]]; then
    fingerprint_section="$(cat <<FPRINT

## Project Context (auto-generated)
${fingerprint}
FPRINT
)"
    log "│  Fingerprint: $(echo "$fingerprint" | grep -cE '^- ' || echo 0) items injected"
  fi

  # Blast radius preflight gate — refuse auto_safe execution on critical radius
  local blast_json blast_warning_section=""
  blast_json="$(compute_blast_radius "$prompt" "$repo_path" || true)"
  if [[ -n "$blast_json" ]]; then
    local blast_severity blast_affected
    blast_severity=$(echo "$blast_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("severity",""))
except: print("")' 2>/dev/null || echo "")
    blast_affected=$(echo "$blast_json" | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("affected",0)))
except: print(0)' 2>/dev/null || echo "0")

    if [[ "$blast_severity" = "critical" && "$authority" = "auto_safe" ]]; then
      log "│  ⚠ GATE: blast radius critical (${blast_affected} files) — refusing auto_safe execution"
      update_task_status "$task_id" "failed" "TASK_BLOCKED: blast_radius_critical — ${blast_affected} files affected. Requires operator approval."
      return 0
    fi

    blast_warning_section="$(render_blast_warning "$blast_json")"
    if [[ -n "$blast_warning_section" ]]; then
      log "│  Blast radius: ${blast_severity} (${blast_affected} files) — warning injected"
    fi
  fi

  # Build mission prompt
  local mission_prompt
  mission_prompt="$(cat <<MISSION
# MISSION BRIEF — Autonomous Task

You are operating autonomously in an unattended Claude Code session.
Read files before modifying them. Be thorough.

## Task
${title}
${blast_warning_section}${fingerprint_section}

## Instructions
${prompt}

## Constraints
- Do NOT ask questions — make reasonable decisions and document them
- Do NOT deploy to production unless the task explicitly says to
- Do NOT run destructive commands (rm -rf, DROP TABLE, git reset --hard)
- Commit your work with descriptive messages when a logical unit is complete
- ONLY change what the task specifies — do not fix unrelated code or make bonus improvements
- If you get stuck, write a summary of what you tried and stop

## Completion
When done, output exactly: TASK_COMPLETE
If blocked, output exactly: TASK_BLOCKED: <reason>
MISSION
)"

  # Snapshot tree state before task runs (to avoid auto-committing pre-existing files)
  local pre_snapshot
  pre_snapshot=$(mktemp /tmp/cc-pre-XXXXXX.txt)
  cd "$repo_path"
  git diff --name-only 2>/dev/null > "$pre_snapshot"
  git ls-files --others --exclude-standard 2>/dev/null >> "$pre_snapshot"

  # Execute
  local output_file exit_code=0
  output_file=$(mktemp /tmp/cc-task-XXXXXX.json)
  trap "rm -f ${output_file} ${pre_snapshot} ${HOOKS_SETTINGS}" RETURN

  log "│  Starting Claude Code session..."

  cd "$repo_path"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  eval "$(build_claude_cmd "$mission_prompt" "$max_turns")" \
    < /dev/null > "$output_file" 2>&1 || exit_code=$?

  # Extract result
  local result_text
  result_text=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("result", ""))
except:
    with open(sys.argv[1]) as f:
        print(f.read()[:4000])
' "$output_file" 2>/dev/null || cat "$output_file" | head -c 4000)

  # ─── Handle commits, push, PR ──────────────────────────────
  local pr_url=""
  cd "$repo_path"

  if $use_branch; then
    local commit_count
    commit_count=$(git rev-list main..HEAD --count 2>/dev/null || echo "0")

    # Only auto-commit files that the TASK created/modified (not pre-existing dirty files)
    local task_dirty_files=()
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if ! grep -qxF "$f" "$pre_snapshot" 2>/dev/null; then
        task_dirty_files+=("$f")
      fi
    done < <(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

    if [[ ${#task_dirty_files[@]} -gt 0 ]]; then
      log "│  Auto-committing ${#task_dirty_files[@]} task-created files (skipping pre-existing changes)"
      for f in "${task_dirty_files[@]}"; do
        git add "$f" 2>/dev/null
      done
      git commit -m "auto: uncommitted changes from task ${task_id:0:8}

Task: ${title}" 2>/dev/null || true
      commit_count=$((commit_count + 1))
    fi

    # ── Ratchet post-validation (#16) ─────────────────────────
    local ratchet_verdict=""
    if [[ "$RATCHET_ENABLED" = "true" && "$commit_count" -gt 0 ]]; then
      log "│  Ratchet: validating branch…"
      local ratchet_post
      ratchet_post="$(ratchet_snapshot "$repo_path" post)"
      log "│  Ratchet post:     ${ratchet_post}"
      ratchet_verdict="$(ratchet_decision "$RATCHET_BASELINE" "$ratchet_post")"
      local ratchet_rc=$?
      log "│  Ratchet verdict:  ${ratchet_verdict}"

      if [[ $ratchet_rc -ne 0 ]]; then
        log "│  Ratchet REVERT — dropping branch and skipping PR"
        git checkout main 2>/dev/null || git checkout master 2>/dev/null
        git branch -D "$branch" 2>/dev/null || true
        branch=""
        commit_count=0
        if [[ "$stashed" == "true" ]]; then
          git stash pop 2>/dev/null && log "│  Restored stashed changes" || true
          stashed=false
        fi
        result_text="[ratchet_revert] ${ratchet_verdict}

${result_text}"
        update_task_status "$task_id" "failed" "ratchet revert: ${ratchet_verdict}"
        log "└─ Task reverted by ratchet gate"
        return 1
      fi
    fi

    # Push and create PR if there are commits
    if [[ "$commit_count" -gt 0 ]]; then
      log "│  Pushing ${commit_count} commit(s) to ${branch}..."
      git push -u origin "$branch" 2>/dev/null || true

      # Create PR if gh CLI is available
      if command -v gh >/dev/null 2>&1; then
        local remote_url repo_slug
        remote_url=$(git remote get-url origin 2>/dev/null)
        repo_slug=$(echo "$remote_url" | sed -E 's|.*github\.com[:/](.+)(\.git)?$|\1|' | sed 's/\.git$//')

        pr_url=$(gh pr create \
          --repo "$repo_slug" \
          --base main \
          --head "$branch" \
          --title "[auto] ${title}" \
          --body "$(cat <<PRBODY
## Autonomous Task

**Task ID**: \`${task_id:0:8}\`
**Exit code**: ${exit_code}

## Prompt
${prompt:0:2000}

## Result
${result_text:0:2000}

---
Generated by [cc-taskrunner](https://github.com/Stackbilt-dev/cc-taskrunner)
PRBODY
)" 2>/dev/null || echo "")

        if [[ -n "$pr_url" ]]; then
          log "│  PR created: ${pr_url}"
          result_text="${result_text}

[cc-taskrunner] PR: ${pr_url}"
        else
          log "│  WARNING: PR creation failed"
        fi
      fi
    else
      log "│  No commits on branch — cleaning up"
      git checkout main 2>/dev/null || git checkout master 2>/dev/null
      git branch -D "$branch" 2>/dev/null || true
      branch=""
      if [[ "$stashed" == "true" ]]; then
        git stash pop 2>/dev/null && log "│  Restored stashed changes" || true
        stashed=false
      fi
    fi

    # Return to main
    git checkout main 2>/dev/null || git checkout master 2>/dev/null

    # Restore stashed changes
    if [[ "$stashed" == "true" ]]; then
      git stash pop 2>/dev/null && log "│  Restored stashed changes" || log "│  WARNING: stash pop failed"
    fi
  fi

  # Check completion signal
  if echo "$result_text" | grep -qF "TASK_COMPLETE"; then
    log "│  Completion signal found"
  elif echo "$result_text" | grep -qF "TASK_BLOCKED"; then
    log "│  Task reported BLOCKED"
    exit_code=2
  else
    log "│  WARNING: No completion signal in output"
    if [[ $exit_code -eq 0 ]]; then
      exit_code=3
    fi
  fi

  # Update queue
  local status="completed"
  [[ $exit_code -ne 0 ]] && status="failed"
  update_task_status "$task_id" "$status" "$result_text"

  if [[ $exit_code -eq 0 ]]; then
    log "└─ COMPLETED${pr_url:+ (PR: ${pr_url})}"
  else
    log "└─ FAILED (exit code ${exit_code})"
  fi

  TASKS_RUN=$((TASKS_RUN + 1))
  return $exit_code
}

# ─── Handle subcommands ─────────────────────────────────────

if [[ "$ACTION" == "add" ]]; then
  add_task "$*"
  exit 0
fi

if [[ "$ACTION" == "list" ]]; then
  list_tasks
  exit 0
fi

# ─── Main loop ───────────────────────────────────────────────

main() {
  ensure_hooks_settings

  log "cc-taskrunner starting"
  log "  Queue:  ${QUEUE_FILE}"
  log "  Safety: ${SAFETY_DIR}"
  log "  Max:    $([ "$MAX_TASKS" -eq 0 ] && echo 'unlimited' || echo "$MAX_TASKS")"
  log "  Turns:  ${MAX_TURNS}"
  log "  Mode:   $(${DRY_RUN} && echo 'DRY RUN' || echo 'LIVE')"

  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    log "  GitHub: authenticated"
  else
    log "  GitHub: not authenticated (PRs will be skipped)"
  fi
  log ""

  while true; do
    if [[ "$MAX_TASKS" -gt 0 && "$TASKS_RUN" -ge "$MAX_TASKS" ]]; then
      log "Task limit reached (${TASKS_RUN}/${MAX_TASKS}). Stopping."
      break
    fi

    local task_json
    task_json=$(fetch_next_task)

    if [[ -z "$task_json" ]]; then
      if $LOOP_MODE; then
        log "Queue empty. Polling again in ${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        continue
      else
        log "Queue empty. ${TASKS_RUN} task(s) completed. Done."
        break
      fi
    fi

    execute_task "$task_json" || true
    sleep 2
  done
}

main
