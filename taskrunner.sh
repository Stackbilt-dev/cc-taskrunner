#!/usr/bin/env bash
# cc-taskrunner — Autonomous task queue for Claude Code
#
# Executes tasks from a local queue file using headless Claude Code sessions
# with safety hooks, branch-per-task isolation, and automatic PR creation.
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

# Force line-buffered stdout so output isn't truncated when run in background
# (e.g. Claude Code's run_in_background or nohup). Fixes #2.
if [[ -z "${CC_UNBUFFERED:-}" ]] && command -v stdbuf >/dev/null 2>&1; then
  export CC_UNBUFFERED=1
  exec stdbuf -oL "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_FILE="${CC_QUEUE_FILE:-${SCRIPT_DIR}/queue.json}"
HOOKS_DIR="${SCRIPT_DIR}/hooks"
HOOKS_SETTINGS="${HOOKS_DIR}/settings.json"
POLL_INTERVAL="${CC_POLL_INTERVAL:-60}"
MAX_TASKS="${CC_MAX_TASKS:-0}"  # 0 = unlimited
MAX_TURNS="${CC_MAX_TURNS:-25}"
CIRCUIT_BREAKER_THRESHOLD="${CC_CIRCUIT_BREAKER:-3}"
DRY_RUN=false
LOOP_MODE=false
TASKS_RUN=0

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
  local task_id="$1" status="$2" result="${3:-}" autopsy="${4:-}"
  QUEUE_FILE_PY="$QUEUE_FILE" python3 -c "
import json, sys
with open('$QUEUE_FILE', 'r') as f:
    queue = json.load(f)
for t in queue:
    if t['id'] == sys.argv[1]:
        t['status'] = sys.argv[2]
        if sys.argv[3]:
            t['result'] = sys.argv[3][:4000]
        autopsy_json = sys.argv[4] if len(sys.argv) > 4 else ''
        if autopsy_json:
            t['autopsy'] = json.loads(autopsy_json)
        if sys.argv[2] == 'running':
            import datetime
            t['started_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        elif sys.argv[2] in ('completed', 'failed'):
            import datetime
            t['finished_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        break
with open('$QUEUE_FILE', 'w') as f:
    json.dump(queue, f, indent=2)
" "$task_id" "$status" "$result" "$autopsy"
}

# ─── Failure classification ─────────────────────────────────

classify_failure() {
  local exit_code="$1" result_text="$2"
  # Outputs a JSON autopsy object for the failure
  EXIT_CODE="$exit_code" RESULT="$result_text" python3 -c '
import json, os
exit_code = int(os.environ["EXIT_CODE"])
result = os.environ["RESULT"]
rl = result.lower()
if "repo not found" in rl:
    kind, retryable = "repo_not_found", False
elif "auth" in rl and ("401" in rl or "preflight" in rl or "authentication" in rl):
    kind, retryable = "auth_failure", True
elif "max_turns" in rl or "error_max_turns" in rl:
    kind, retryable = "max_turns_exceeded", True
elif "uncommitted" in rl:
    kind, retryable = "uncommitted_changes", True
elif "no such file" in rl and "claude" in rl:
    kind, retryable = "claude_binary_missing", False
elif "base branch" in rl:
    kind, retryable = "git_branch_error", True
elif "branch" in rl and ("open pr" in rl or "exists on remote" in rl):
    kind, retryable = "branch_conflict", False
else:
    kind, retryable = "unknown", True
print(json.dumps({"kind": kind, "retryable": retryable, "exit_code": exit_code, "result_snippet": result[:200]}))
'
}

# ─── Generate hooks settings ────────────────────────────────

ensure_hooks_settings() {
  if [[ ! -f "$HOOKS_SETTINGS" ]]; then
    log "Generating hooks settings at ${HOOKS_SETTINGS}"
    mkdir -p "$HOOKS_DIR"

    cat > "$HOOKS_SETTINGS" <<SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${HOOKS_DIR}/block-interactive.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${HOOKS_DIR}/safety-gate.sh"
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
            "command": "bash ${HOOKS_DIR}/syntax-check.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
  fi
}

# ─── Resolve base branch ────────────────────────────────────

resolve_base_branch() {
  local repo_path="$1"
  cd "$repo_path"

  # Try remote HEAD (most reliable for the repo's default branch)
  local remote_head
  remote_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true

  if [[ -n "$remote_head" ]]; then
    echo "$remote_head"
    return
  fi

  # Fall back to checking for common branch names
  for candidate in main master; do
    if git rev-parse --verify "refs/heads/${candidate}" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done

  err "Could not determine base branch for ${repo_path}"
  return 1
}

# ─── Package manager / test detection ───────────────────────

detect_package_manager() {
  local dir="$1"
  if [[ -f "$dir/pnpm-lock.yaml" || -f "$dir/pnpm-workspace.yaml" ]]; then
    echo "pnpm"
    return
  fi
  echo "npm"
}

detect_test_command() {
  local repo_path="$1"
  local rel dir manager
  for rel in "." "web" "e2e"; do
    if [[ "$rel" == "." ]]; then
      dir="$repo_path"
    else
      dir="$repo_path/$rel"
    fi
    [[ -f "$dir/package.json" ]] || continue
    if python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
scripts = data.get("scripts", {})
print("yes" if scripts.get("test") else "no")
' "$dir/package.json" 2>/dev/null | grep -q '^yes$'; then
      manager=$(detect_package_manager "$dir")
      if [[ "$rel" == "." ]]; then
        echo "${manager} test"
      elif [[ "$manager" == "pnpm" ]]; then
        echo "pnpm --dir ${rel} test"
      else
        echo "npm --prefix ${rel} test"
      fi
      return 0
    fi
  done
  return 1
}

# ─── Preflight JSON ─────────────────────────────────────────

build_preflight_json() {
  local repo="$1" repo_path="$2" base_branch="${3:-}"
  local repo_exists=true
  local git_repo=false
  local test_command=""
  local warnings=()

  if [[ ! -d "$repo_path" ]]; then
    repo_exists=false
    warnings+=("Resolved repo path does not exist")
  fi

  if [[ -d "$repo_path" ]] && git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_repo=true
  elif [[ -d "$repo_path" ]]; then
    warnings+=("Resolved repo path is not a git repository")
  fi

  test_command=$(detect_test_command "$repo_path" 2>/dev/null || echo "")

  PREFLIGHT_WARNINGS=$(printf '%s\x1f' "${warnings[@]}") \
  PREFLIGHT_REPO="$repo" \
  PREFLIGHT_REPO_EXISTS="$repo_exists" \
  PREFLIGHT_REPO_PATH="$repo_path" \
  PREFLIGHT_GIT_REPO="$git_repo" \
  PREFLIGHT_BASE_BRANCH="$base_branch" \
  PREFLIGHT_TEST_COMMAND="$test_command" \
  python3 -c '
import json, os
warnings = [w for w in os.environ.get("PREFLIGHT_WARNINGS", "").split("\x1f") if w]
print(json.dumps({
    "repo": os.environ.get("PREFLIGHT_REPO", ""),
    "repo_exists": os.environ.get("PREFLIGHT_REPO_EXISTS", "false") == "true",
    "repo_path": os.environ.get("PREFLIGHT_REPO_PATH") or None,
    "git_repo": os.environ.get("PREFLIGHT_GIT_REPO", "false") == "true",
    "base_branch": os.environ.get("PREFLIGHT_BASE_BRANCH") or None,
    "test_command": os.environ.get("PREFLIGHT_TEST_COMMAND") or None,
    "warnings": warnings,
}))
'
}

render_preflight_prompt() {
  local preflight_json="$1"
  PREFLIGHT="$preflight_json" python3 -c '
import json, os
raw = os.environ.get("PREFLIGHT", "")
if not raw:
    print("")
    raise SystemExit(0)
data = json.loads(raw)
lines = ["## Task Preflight"]
if data.get("repo_path"):
    lines.append("- Repo path: " + str(data["repo_path"]))
if data.get("base_branch"):
    lines.append("- Base branch: " + str(data["base_branch"]))
if data.get("test_command"):
    lines.append("- Detected test command: " + str(data["test_command"]))
warnings = data.get("warnings") or []
if warnings:
    lines.append("- Warnings:")
    for warning in warnings:
        lines.append(f"  - {warning}")
else:
    lines.append("- Warnings: none")
print("\n".join(lines))
'
}

# ─── Large-file LOC guardrail ───────────────────────────────

adjust_max_turns_for_loc() {
  local prompt="$1" repo_path="$2" current_max="$3"
  local new_max="$current_max"

  local files
  files=$(echo "$prompt" | grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|rs|go|sh|sql)' | sort -u)

  if [[ -z "$files" ]]; then
    echo "$new_max"
    return
  fi

  local max_loc=0
  local largest_file=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local full_path="${repo_path}/${f}"
    if [[ -f "$full_path" ]]; then
      local loc
      loc=$(wc -l < "$full_path" 2>/dev/null || echo "0")
      loc=$(echo "$loc" | tr -d ' ')
      if [[ "$loc" -gt "$max_loc" ]]; then
        max_loc="$loc"
        largest_file="$f"
      fi
    fi
  done <<< "$files"

  if [[ "$max_loc" -gt 1500 ]]; then
    new_max=50
    log "│  Large file detected: ${largest_file} (${max_loc} LOC) -> max_turns bumped to ${new_max}" >&2
  elif [[ "$max_loc" -gt 800 ]]; then
    new_max=40
    log "│  Large file detected: ${largest_file} (${max_loc} LOC) -> max_turns bumped to ${new_max}" >&2
  fi

  if [[ "$new_max" -lt "$current_max" ]]; then
    new_max="$current_max"
  fi

  # Repo-complexity baseline: large multi-file repos need more turns even without explicit file paths
  if [[ -d "$repo_path/src" ]]; then
    local ts_count
    ts_count=$(find "$repo_path/src" -name "*.ts" -o -name "*.tsx" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ts_count" -gt 80 && "$new_max" -lt 40 ]]; then
      new_max=40
      log "│  Complex repo detected (${ts_count} TS files) -> max_turns baseline ${new_max}" >&2
    fi
  fi

  echo "$new_max"
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

# ─── Auth probe ──────────────────────────────────────────────

auth_probe() {
  # Verify claude CLI exists and can authenticate before burning a task attempt.
  if ! command -v claude >/dev/null 2>&1; then
    err "Claude binary not found in PATH"
    echo "Auth preflight failed: claude binary not found in PATH"
    return 1
  fi
  local probe_output
  if ! probe_output=$(unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; timeout 30 claude -p "reply with exactly: AUTH_OK" --max-turns 1 < /dev/null 2>&1); then
    if echo "$probe_output" | grep -qi "auth\|401\|credential\|API key"; then
      err "Claude auth probe failed — API key may be expired"
      echo "Auth preflight failed: ${probe_output:0:200}"
      return 1
    fi
    # Non-auth failure (timeout, etc.) — proceed anyway
    log "│  Auth probe inconclusive (${probe_output:0:80}), proceeding..."
  fi
  return 0
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

  # Resolve repo path
  local repo_path
  if [[ "$repo" == "." ]]; then
    repo_path="$(pwd)"
  elif [[ -d "$repo" ]]; then
    repo_path="$(cd "$repo" && pwd)"
  else
    err "Repo not found: ${repo}"
    local autopsy
    autopsy=$(classify_failure 1 "Repo not found: ${repo}")
    update_task_status "$task_id" "failed" "Repo not found: ${repo}" "$autopsy"
    return 1
  fi

  # Large-file LOC guardrail — bump max_turns for big files
  max_turns=$(adjust_max_turns_for_loc "$prompt" "$repo_path" "$max_turns")

  # Build preflight report
  local base_branch=""
  if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    base_branch=$(resolve_base_branch "$repo_path" 2>/dev/null || echo "")
  fi
  local preflight_json
  preflight_json=$(build_preflight_json "$repo" "$repo_path" "$base_branch")
  log "│  Preflight: $(echo "$preflight_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); w=d.get("warnings",[]); print(f"ok ({len(w)} warnings)" if d.get("repo_exists") else "WARN: repo missing")' 2>/dev/null || echo "built")"

  # Auth probe — verify claude CLI works before burning a task attempt
  local auth_fail_msg
  if auth_fail_msg=$(auth_probe 2>&1); then
    : # auth OK
  else
    local autopsy
    autopsy=$(classify_failure 1 "$auth_fail_msg")
    update_task_status "$task_id" "failed" "$auth_fail_msg" "$autopsy"
    TASKS_RUN=$((TASKS_RUN + 1))
    return 1
  fi

  # Mark as running
  update_task_status "$task_id" "running"

  # ─── Branch lifecycle ─────────────────────────────────────
  local branch=""
  local use_branch=false
  local stashed=false
  cd "$repo_path"

  # Non-operator tasks get their own branch
  if [[ "$authority" != "operator" ]]; then
    use_branch=true
    branch="auto/${task_id:0:8}"

    # Resolve base branch dynamically
    if [[ -z "$base_branch" ]]; then
      base_branch=$(resolve_base_branch "$repo_path") || {
        local autopsy
        autopsy=$(classify_failure 1 "Could not determine base branch")
        update_task_status "$task_id" "failed" "Could not determine base branch" "$autopsy"
        TASKS_RUN=$((TASKS_RUN + 1))
        return 1
      }
    fi
    log "│  Base:   ${base_branch}"

    # Stash uncommitted changes to protect live work
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      git stash push -m "cc-taskrunner:${task_id:0:8}" --include-untracked 2>/dev/null && stashed=true
      log "│  Stashed uncommitted changes"
    fi

    # Start from base branch
    git checkout "$base_branch" 2>/dev/null || true
    git pull --ff-only 2>/dev/null || true

    # ─── PR state check before branch reuse ─────────────────
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
      if git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
        # Branch exists on remote — check if the PR is still open
        local remote_url repo_slug_check pr_state
        remote_url=$(git remote get-url origin 2>/dev/null)
        repo_slug_check=$(echo "$remote_url" | sed -E 's|.*github\.com[:/](.+)(\.git)?$|\1|' | sed 's/\.git$//')
        pr_state=$(gh pr view "$branch" --repo "$repo_slug_check" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

        if [[ "$pr_state" == "OPEN" ]]; then
          err "Branch ${branch} has an open PR — refusing to reuse"
          local autopsy
          autopsy=$(classify_failure 1 "Branch ${branch} exists on remote with open PR")
          update_task_status "$task_id" "failed" "Branch ${branch} exists on remote; has an open PR" "$autopsy"
          # Restore stash before returning
          if [[ "$stashed" == "true" ]]; then
            git stash pop 2>/dev/null || true
          fi
          TASKS_RUN=$((TASKS_RUN + 1))
          return 1
        fi

        # PR is merged/closed/unknown — safe to delete and recreate
        log "│  Prior branch ${branch} found (PR state: ${pr_state}) — cleaning up"
        git push origin --delete "$branch" 2>/dev/null || true
        git branch -D "$branch" 2>/dev/null || true
      else
        # Local-only branch with no remote: safe to delete and recreate
        git branch -D "$branch" 2>/dev/null || true
      fi
    fi

    # Create task branch
    git checkout -b "$branch" 2>/dev/null
    log "│  Branch: ${branch}"

    # Seed .gitignore to block Windows-path directories that agents sometimes
    # create (e.g. C:\Users\...) which cause git ls-files to hang scanning
    # deeply nested untracked trees like pnpm stores. Fixes #6.
    if ! grep -q '^C:\*' .gitignore 2>/dev/null; then
      {
        echo ""
        echo "# cc-taskrunner: block Windows-path pollution"
        echo "C:*"
      } >> .gitignore
      git add .gitignore 2>/dev/null || true
    fi
  fi

  # Build preflight prompt section
  local preflight_prompt
  preflight_prompt=$(render_preflight_prompt "$preflight_json")

  # Build mission prompt
  local mission_prompt
  mission_prompt="$(cat <<MISSION
# MISSION BRIEF — Autonomous Task

You are operating autonomously in an unattended Claude Code session.
Read files before modifying them. Be thorough.

## Task
${title}

## Instructions
${prompt}

${preflight_prompt}

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
  timeout 30 git diff --name-only 2>/dev/null > "$pre_snapshot"
  timeout 30 git ls-files --others --exclude-standard 2>/dev/null >> "$pre_snapshot"

  # Execute
  local output_file exit_code=0
  output_file=$(mktemp /tmp/cc-task-XXXXXX.json)
  trap "rm -f ${output_file} ${pre_snapshot}" RETURN

  log "│  Starting Claude Code session..."

  cd "$repo_path"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  eval "$(build_claude_cmd "$mission_prompt" "$max_turns")" \
    > "$output_file" 2>&1 || exit_code=$?

  # Detect max_turns exceeded from JSON output
  if grep -qF '"error_max_turns"' "$output_file" 2>/dev/null; then
    log "│  Claude hit max_turns limit (${max_turns} turns)"
    if [[ $exit_code -eq 0 ]]; then
      exit_code=3
    fi
  fi

  # Extract result
  local result_text
  result_text=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    subtype = data.get("subtype", "")
    if subtype == "error_max_turns":
        turns = data.get("num_turns", "?")
        cost = data.get("total_cost_usd", 0)
        print(f"[max_turns_exceeded] Task ran out of turns ({turns} used, ${cost:.2f}). Increase max_turns or simplify the task.")
    else:
        text = data.get("result", "")
        if text and not text.lstrip().startswith("{"):
            print(text)
        elif data.get("output"):
            print(data["output"])
        elif data.get("text"):
            print(data["text"])
        else:
            print(json.dumps(data)[:8000])
except:
    with open(sys.argv[1]) as f:
        print(f.read()[:4000])
' "$output_file" 2>/dev/null || cat "$output_file" | head -c 4000)

  # ─── Handle commits, push, PR ──────────────────────────────
  local pr_url=""
  cd "$repo_path"

  if $use_branch; then
    local commit_count
    commit_count=$(git rev-list "${base_branch}..HEAD" --count 2>/dev/null || echo "0")

    # Only auto-commit files that the TASK created/modified (not pre-existing dirty files)
    local task_dirty_files=()
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if ! grep -qxF "$f" "$pre_snapshot" 2>/dev/null; then
        task_dirty_files+=("$f")
      fi
    done < <(timeout 30 git diff --name-only 2>/dev/null; timeout 30 git ls-files --others --exclude-standard 2>/dev/null)

    if [[ ${#task_dirty_files[@]} -gt 0 ]]; then
      log "│  Auto-committing ${#task_dirty_files[@]} task-created files (skipping pre-existing changes)"
      for f in "${task_dirty_files[@]}"; do
        git add "$f" 2>/dev/null
      done
      git commit -m "auto: uncommitted changes from task ${task_id:0:8}

Task: ${title}" 2>/dev/null || true
      commit_count=$(git rev-list "${base_branch}..HEAD" --count 2>/dev/null || echo "0")
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
          --base "$base_branch" \
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
      git checkout "$base_branch" 2>/dev/null || git checkout main 2>/dev/null || git checkout master 2>/dev/null
      git branch -D "$branch" 2>/dev/null || true
      branch=""
      if [[ "$stashed" == "true" ]]; then
        git stash pop 2>/dev/null && log "│  Restored stashed changes" || true
        stashed=false
      fi
    fi

    # Return to base branch
    git checkout "$base_branch" 2>/dev/null || git checkout main 2>/dev/null || git checkout master 2>/dev/null

    # Restore stashed changes
    if [[ "$stashed" == "true" ]]; then
      git stash pop 2>/dev/null && log "│  Restored stashed changes" || log "│  WARNING: stash pop failed"
    fi
  fi

  # ─── Completion signal check with fallback heuristics ──────
  # Claude often completes work successfully but forgets to emit the exact signal.
  # Check multiple indicators before failing a task that actually succeeded.
  if echo "$result_text" | grep -qF "TASK_COMPLETE"; then
    log "│  Completion signal found"
  elif echo "$result_text" | grep -qF "TASK_BLOCKED"; then
    log "│  Task reported BLOCKED"
    exit_code=2
  else
    # Fallback 1: Did Claude make commits? Strong evidence of real work.
    local has_commits=false
    if $use_branch && [[ -n "$pr_url" ]]; then
      has_commits=true
    elif $use_branch && [[ -n "$branch" ]]; then
      local wt_commits
      wt_commits=$(cd "$repo_path" 2>/dev/null && git rev-list "${base_branch}..${branch}" --count 2>/dev/null || echo "0")
      [[ "$wt_commits" -gt 0 ]] && has_commits=true
    fi

    # Fallback 2: Does output contain natural completion language?
    local has_completion_language=false
    if echo "$result_text" | grep -qiE '(task.*(complete|done|finished)|successfully.*(complet|implement|fix)|all.*changes.*(commit|push|applied)|work.*complete)'; then
      has_completion_language=true
    fi

    if $has_commits; then
      log "│  Completion signal missing but commits detected — treating as success"
    elif $has_completion_language; then
      log "│  Completion signal missing but output indicates completion — treating as success"
    else
      log "│  WARNING: No completion signal in output (no commits, no completion language)"
      if [[ $exit_code -eq 0 ]]; then
        exit_code=3
      fi
    fi
  fi

  # ─── Update queue with result ──────────────────────────────
  local status="completed"
  local autopsy=""
  if [[ $exit_code -ne 0 ]]; then
    status="failed"
    autopsy=$(classify_failure "$exit_code" "$result_text")
  fi
  update_task_status "$task_id" "$status" "$result_text" "$autopsy"

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
  log "  Hooks:  ${HOOKS_DIR}"
  log "  Max:    $([ "$MAX_TASKS" -eq 0 ] && echo 'unlimited' || echo "$MAX_TASKS")"
  log "  Turns:  ${MAX_TURNS}"
  log "  Mode:   $(${DRY_RUN} && echo 'DRY RUN' || echo 'LIVE')"
  log "  Circuit breaker: ${CIRCUIT_BREAKER_THRESHOLD} consecutive failures"

  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    log "  GitHub: authenticated"
  else
    log "  GitHub: not authenticated (PRs will be skipped)"
  fi
  log ""

  local consecutive_failures=0

  while true; do
    if [[ "$MAX_TASKS" -gt 0 && "$TASKS_RUN" -ge "$MAX_TASKS" ]]; then
      log "Task limit reached (${TASKS_RUN}/${MAX_TASKS}). Stopping."
      break
    fi

    # Circuit breaker: stop after N consecutive failures to prevent budget burn
    if [[ "$consecutive_failures" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
      log "CIRCUIT BREAKER: ${consecutive_failures} consecutive failures. Stopping to prevent budget burn."
      log "  Review failed tasks in ${QUEUE_FILE} before restarting."
      break
    fi

    local task_json
    task_json=$(fetch_next_task)

    if [[ -z "$task_json" ]]; then
      if $LOOP_MODE; then
        log "Queue empty. Polling again in ${POLL_INTERVAL}s..."
        consecutive_failures=0
        sleep "$POLL_INTERVAL"
        continue
      else
        log "Queue empty. ${TASKS_RUN} task(s) completed. Done."
        break
      fi
    fi

    if execute_task "$task_json"; then
      consecutive_failures=0
    else
      consecutive_failures=$((consecutive_failures + 1))
      log "  (consecutive failures: ${consecutive_failures}/${CIRCUIT_BREAKER_THRESHOLD})"
    fi
    sleep 2
  done
}

main
