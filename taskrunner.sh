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
  local output
  output=$(timeout 20 charter surface --root "$repo_path" --markdown 2>/dev/null || true)
  if [[ -z "$output" ]]; then return 0; fi
  # Cap at ~80 lines to keep mission brief under budget
  echo "$output" | head -n 80
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
import json, re, sys

with open('$QUEUE_FILE') as f:
    queue = json.load(f)

def extract_issue_refs(title):
    \"\"\"Extract issue references like [Issue #123] or #123 from a task title.\"\"\"
    refs = set()
    for m in re.finditer(r'\[Issue\s+#(\d+)\]', title, re.IGNORECASE):
        refs.add(int(m.group(1)))
    return refs

# Build lookup for task statuses
status_by_id = {t['id']: t.get('status', 'pending') for t in queue}
completed_ids = {tid for tid, s in status_by_id.items() if s == 'completed'}
failed_ids = {tid for tid, s in status_by_id.items() if s == 'failed'}

# Collect issue refs from running and recently completed tasks
active_issue_refs = set()
for t in queue:
    if t.get('status') in ('running', 'completed'):
        active_issue_refs.update(extract_issue_refs(t.get('title', '')))

# Find first pending task that passes all gates
for t in queue:
    if t.get('status') != 'pending':
        continue

    # Gate 1: Dedup — skip if an active task covers the same issue
    task_refs = extract_issue_refs(t.get('title', ''))
    if task_refs and task_refs & active_issue_refs:
        t['status'] = 'cancelled'
        t['result'] = 'Skipped: duplicate of running/completed task for issue #' + ', #'.join(str(r) for r in sorted(task_refs & active_issue_refs))
        with open('$QUEUE_FILE', 'w') as f:
            json.dump(queue, f, indent=2)
        print(f'[dedup] Skipping task {t[\"id\"][:8]}: duplicate issue ref', file=sys.stderr)
        continue

    # Gate 2: blocked_by — all blockers must be completed
    blockers = t.get('blocked_by', []) or []
    if blockers:
        failed_blockers = [b for b in blockers if b in failed_ids]
        if failed_blockers:
            t['status'] = 'cancelled'
            t['result'] = f'Dependency failed: {failed_blockers[0]}'
            with open('$QUEUE_FILE', 'w') as f:
                json.dump(queue, f, indent=2)
            print(f'[cascade] Cancelling task {t[\"id\"][:8]}: blocker failed', file=sys.stderr)
            continue
        unresolved = [b for b in blockers if b not in completed_ids]
        if unresolved:
            print(f'[blocked] Skipping task {t[\"id\"][:8]}: waiting on {len(unresolved)} blocker(s)', file=sys.stderr)
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
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${HOOKS_DIR}/stop-checkpoint.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
  fi
}

# ─── Cross-repo dir detection ────────────────────────────────

detect_cross_repo_dirs() {
  # Scan task prompt for references to other repos under REPOS_DIR.
  # Returns newline-separated list of repo paths (excluding the primary repo).
  local prompt="$1" primary_repo="$2"

  [[ -z "$REPOS_DIR" ]] && return 0

  local dir dirname
  for dir in "$REPOS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    dirname=$(basename "$dir")
    [[ "$dirname" == "$primary_repo" ]] && continue
    if echo "$prompt" | grep -qi "$dirname" && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "$dir"
    fi
  done
}

# ─── Build Claude command ────────────────────────────────────

build_claude_cmd() {
  local prompt="$1" max_turns="$2" add_dirs="${3:-}"

  local cmd=(
    claude
    -p "$prompt"
    --bare
    --dangerously-skip-permissions
    --output-format json
    --max-turns "$max_turns"
    --settings "$HOOKS_SETTINGS"
  )
  # --bare: skip CLAUDE.md discovery, MCP init, auto-memory for faster startup.
  # Hooks still load via explicit --settings. Work dir passed via --add-dir below.

  # Cross-repo access and CLAUDE.md discovery via --add-dir
  if [[ -n "$add_dirs" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" && -d "$dir" ]] && cmd+=(--add-dir "$dir")
    done <<< "$add_dirs"
  fi

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
  cd "$repo_path"

  # Non-operator tasks get their own branch
  if [[ "$authority" != "operator" ]]; then
    use_branch=true
    branch="auto/${task_id:0:8}"

    # Stash uncommitted changes to protect live work
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      git stash push -m "cc-taskrunner:${task_id:0:8}" --include-untracked 2>/dev/null && stashed=true
      log "│  Stashed uncommitted changes"
    fi

    # Start from main
    git checkout main 2>/dev/null || git checkout master 2>/dev/null
    git pull --ff-only 2>/dev/null || true

    # Check both local AND remote refs for existing branch (#14)
    # Prior bug: only checked local refs, missed remote-only branches left by
    # worktree cleanup. Those stale remote branches caused push failures.
    git fetch origin --prune --quiet 2>/dev/null || true
    local has_local_branch=false has_remote_branch=false
    git rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1 && has_local_branch=true
    git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null && has_remote_branch=true

    if $has_local_branch || $has_remote_branch; then
      if $has_remote_branch; then
        # Check if a stale PR is still open — close it
        if command -v gh >/dev/null 2>&1; then
          local remote_url_check repo_slug_check pr_state
          remote_url_check=$(git remote get-url origin 2>/dev/null)
          repo_slug_check=$(echo "$remote_url_check" | sed -E 's|.*github\.com[:/](.+)(\.git)?$|\1|' | sed 's/\.git$//')
          pr_state=$(gh pr view "$branch" --repo "$repo_slug_check" --json state --jq .state 2>/dev/null || echo "NONE")
          if [[ "$pr_state" == "OPEN" ]]; then
            log "│  Closing stale PR on ${branch} (prior run left it open)"
            gh pr close "$branch" --repo "$repo_slug_check" --comment "Superseded by task re-run (${task_id})" 2>/dev/null || true
          fi
        fi
        git push origin --delete "$branch" 2>/dev/null || true
      fi
      if $has_local_branch; then
        git branch -D "$branch" 2>/dev/null || true
      fi
    fi

    git checkout -b "$branch"
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

  # Build mission prompt
  local mission_prompt
  mission_prompt="$(cat <<MISSION
# MISSION BRIEF — Autonomous Task

You are operating autonomously in an unattended Claude Code session.
Read files before modifying them. Be thorough.

## Task
${title}
${fingerprint_section}

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
  timeout 30 git diff --name-only 2>/dev/null > "$pre_snapshot"
  timeout 30 git ls-files --others --exclude-standard 2>/dev/null >> "$pre_snapshot"

  # Execute
  local output_file checkpoint_file exit_code=0
  output_file=$(mktemp /tmp/cc-task-XXXXXX.json)
  checkpoint_file=$(mktemp /tmp/cc-task-checkpoint-XXXXXX.json)
  trap "rm -f ${output_file} ${pre_snapshot} ${checkpoint_file}" RETURN

  # Detect cross-repo dirs for --add-dir (prompt may reference other repos)
  local cross_repo_dirs=""
  if [[ -n "$REPOS_DIR" ]]; then
    cross_repo_dirs=$(detect_cross_repo_dirs "$prompt $title" "$(basename "$repo_path")" 2>/dev/null || echo "")
    if [[ -n "$cross_repo_dirs" ]]; then
      log "│  Cross-repo access: $(echo "$cross_repo_dirs" | tr '\n' ',' | sed 's/,$//')"
    fi
  fi

  # --bare requires explicit ANTHROPIC_API_KEY (OAuth/keychain disabled)
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    log "│  WARNING: ANTHROPIC_API_KEY not set — --bare mode requires explicit API key"
  fi

  # --bare skips CLAUDE.md auto-discovery; always pass repo_path as first --add-dir
  local all_dirs="$repo_path"
  if [[ -n "$cross_repo_dirs" ]]; then
    all_dirs="${all_dirs}
${cross_repo_dirs}"
  fi

  log "│  Starting Claude Code session..."

  cd "$repo_path"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  export CC_CHECKPOINT_FILE="$checkpoint_file"
  eval "$(build_claude_cmd "$mission_prompt" "$max_turns" "$all_dirs")" \
    < /dev/null > "$output_file" 2>&1 || exit_code=$?
  unset CC_CHECKPOINT_FILE

  # Detect max_turns exceeded from JSON output (#15)
  local max_turns_exceeded=false
  if grep -qF '"error_max_turns"' "$output_file" 2>/dev/null; then
    max_turns_exceeded=true
    log "│  Claude hit max_turns limit (${max_turns} turns) — checking for completion evidence"
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
        else:
            print("")
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
    done < <(timeout 30 git diff --name-only 2>/dev/null; timeout 30 git ls-files --others --exclude-standard 2>/dev/null)

    if [[ ${#task_dirty_files[@]} -gt 0 ]]; then
      log "│  Auto-committing ${#task_dirty_files[@]} task-created files (skipping pre-existing changes)"
      for f in "${task_dirty_files[@]}"; do
        git add "$f" 2>/dev/null
      done
      git commit -m "auto: uncommitted changes from task ${task_id:0:8}

Task: ${title}" 2>/dev/null || true
      commit_count=$((commit_count + 1))
    fi

    # Push and create PR if there are commits
    if [[ "$commit_count" -gt 0 ]]; then
      log "│  Pushing ${commit_count} commit(s) to ${branch}..."
      git push --force-with-lease -u origin "$branch" 2>/dev/null || true

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

  # Annotate result text with max_turns info if applicable (#15)
  if $max_turns_exceeded; then
    result_text="[max_turns_exceeded] Task ran out of turns (${max_turns} used). Increase max_turns or simplify the task.

${result_text}"
  fi

  # Check completion signal — search both the extracted result and the raw
  # JSON output (the signal may be nested or split across JSON fields).
  local signal_found=false
  if echo "$result_text" | grep -qF "TASK_COMPLETE"; then
    signal_found=true
  elif grep -qF "TASK_COMPLETE" "$output_file" 2>/dev/null; then
    signal_found=true
  fi

  if $signal_found; then
    log "│  Completion signal found"
  elif echo "$result_text" | grep -qF "TASK_BLOCKED" || grep -qF "TASK_BLOCKED" "$output_file" 2>/dev/null; then
    log "│  Task reported BLOCKED"
    exit_code=2
  else
    log "│  WARNING: No completion signal in output"
    # Determine commit count for implicit-success check
    local final_commit_count="${commit_count:-0}"
    if [[ $exit_code -eq 0 && "$final_commit_count" -gt 0 ]]; then
      log "│  Exit code 0 with ${final_commit_count} commit(s) — treating as implicit success"
    elif [[ $exit_code -eq 0 ]]; then
      log "│  Exit code 0 but no commits — failing as incomplete"
      exit_code=3
    fi
    # If exit_code was already non-zero, keep it as-is (don't override to 3)
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
  log "  Hooks:  ${HOOKS_DIR}"
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
