<div align="center">
<img src="assets/banner.png" alt="cc-taskrunner — autonomous code pipeline" width="100%" />
</div>

# cc-taskrunner

Autonomous task queue for [Claude Code](https://code.claude.com/docs) with safety hooks, branch isolation, and automatic PR creation.

Queue tasks. Go to sleep. Wake up to PRs.

```
$ ./taskrunner.sh add "Write unit tests for the auth middleware"
Added task a1b2c3d4: Write unit tests for the auth middleware

$ ./taskrunner.sh --max 5
[09:15:00] cc-taskrunner starting
[09:15:00]   Queue:  ./queue.json
[09:15:00]   GitHub: authenticated
[09:15:01] ┌─ Task: Write unit tests for the auth middleware
[09:15:01] │  Branch: auto/a1b2c3d4
[09:15:01] │  Starting Claude Code session...
[09:17:42] │  Pushing 3 commit(s) to auto/a1b2c3d4...
[09:17:44] │  PR created: https://github.com/you/repo/pull/42
[09:17:44] └─ COMPLETED (PR: https://github.com/you/repo/pull/42)
```

## Why This Exists

Claude Code is powerful in interactive sessions. But there's no built-in way to:

- **Queue tasks** and run them unattended (overnight, during meetings, in CI)
- **Isolate changes** on branches so autonomous work doesn't touch main
- **Block dangerous operations** when nobody's watching
- **Create PRs automatically** so you review diffs, not raw commits

cc-taskrunner fills that gap. It's the execution layer between "Claude can write code" and "Claude can ship code safely."

## Quick Start

```bash
# Clone
git clone https://github.com/Stackbilt-dev/cc-taskrunner.git
cd cc-taskrunner

# Make executable
chmod +x taskrunner.sh hooks/*.sh

# Queue a task (runs in current directory by default)
./taskrunner.sh add "Add error handling to the API routes in src/routes.ts"

# Run it
./taskrunner.sh
```

**Requirements:** bash 4+, python3, jq, [Claude Code CLI](https://code.claude.com/docs) (`claude` on PATH). Optional: `gh` CLI for automatic PR creation.

## Usage

### Queue Tasks

```bash
# Simple — runs in current directory
./taskrunner.sh add "Fix the null check bug in parser.ts"

# View the queue
./taskrunner.sh list
```

For more control, edit `queue.json` directly:

```json
[
  {
    "id": "task-001",
    "title": "Add rate limiting to API",
    "repo": "/path/to/your/project",
    "prompt": "Read src/middleware.ts. Add rate limiting using a sliding window. Max 100 requests per minute per IP. Write tests.",
    "authority": "auto_safe",
    "max_turns": 20,
    "status": "pending"
  },
  {
    "id": "task-002",
    "title": "Add rate limit tests",
    "repo": "/path/to/your/project",
    "prompt": "Write integration tests for the rate limiting middleware added in task-001.",
    "authority": "auto_safe",
    "max_turns": 15,
    "blocked_by": ["task-001"],
    "status": "pending"
  }
]
```

### Task Dependencies

Use `blocked_by` to create dependency chains (DAGs). A task won't run until all its blockers have completed:

```json
{
  "id": "task-003",
  "title": "Deploy after tests pass",
  "blocked_by": ["task-001", "task-002"],
  "status": "pending"
}
```

If a blocker fails, all tasks that depend on it are automatically cancelled.

### Run Tasks

```bash
# Run until queue empty
./taskrunner.sh

# Run at most N tasks
./taskrunner.sh --max 5

# Loop forever (poll every 60s for new tasks)
./taskrunner.sh --loop

# Preview without executing
./taskrunner.sh --dry-run

# Custom turn limit (default: 25)
./taskrunner.sh --turns 15
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_QUEUE_FILE` | `./queue.json` | Path to the task queue file |
| `CC_POLL_INTERVAL` | `60` | Seconds between polls in `--loop` mode |
| `CC_MAX_TASKS` | `0` (unlimited) | Max tasks per run |
| `CC_MAX_TURNS` | `25` | Default Claude Code turns per task |

## Safety Architecture

Three layers of protection. All three must be bypassed for something bad to happen.

```
cc-taskrunner
  │
  ├── Layer 1: Safety Hooks
  │   ├── block-interactive.sh   → blocks AskUserQuestion
  │   ├── safety-gate.sh         → blocks rm -rf, git push --force,
  │   │                            DROP TABLE, deploys, secret access
  │   └── syntax-check.sh        → warns on TypeScript errors after edits
  │
  ├── Layer 2: CLI Constraints
  │   ├── --max-turns N          → caps agentic loops
  │   ├── --output-format json   → structured output for parsing
  │   └── --settings hooks.json  → loads safety hooks
  │
  └── Layer 3: Mission Brief
      ├── "Do NOT ask questions"
      ├── "Do NOT deploy to production"
      ├── "Do NOT run destructive commands"
      └── "Output TASK_COMPLETE when done"
```

### Layer 1: Hooks

**block-interactive.sh** — When Claude tries to ask a question at 3 AM, nobody's there to answer. This hook forces it to make a decision and document the reasoning instead of hanging indefinitely.

**safety-gate.sh** — Blocks destructive operations before they execute:
- `rm -rf`, `rm -r /` — filesystem destruction
- `git reset --hard`, `git push --force` — history destruction
- `DROP TABLE`, `TRUNCATE TABLE` — database destruction
- `wrangler deploy`, `kubectl apply`, `terraform apply` — production deploys
- Secret/token access via echo

**syntax-check.sh** — Advisory (never blocks). After any file edit, runs TypeScript compiler to catch errors immediately rather than 50 tool calls later.

### Layer 2: CLI Flags

Claude Code runs with `--max-turns` to prevent infinite loops and `--dangerously-skip-permissions` with safety hooks loaded via `--settings`. The hooks file is auto-generated on first run.

### Layer 3: Mission Brief

Every task gets a structured prompt with explicit constraints. The agent is told what NOT to do, scoped to only the task's changes, and required to output a completion signal (`TASK_COMPLETE` or `TASK_BLOCKED`).

**Completion detection** uses a layered approach to avoid false failures:

1. The signal (`TASK_COMPLETE` / `TASK_BLOCKED`) is searched in both the extracted result text and the raw JSON output file
2. If no signal is found but Claude exited cleanly (exit code 0) **and** produced commits on the task branch, the task is treated as an implicit success with a logged warning
3. Exit code 3 (no completion signal) is only assigned when no signal is found **and** either Claude exited non-zero or no commits were produced

## Branch Isolation

Every task runs on its own branch (`auto/{task-id}`). Main is never directly modified.

```
main ─────────────────────────────────────────── (untouched)
  │
  ├── auto/a1b2c3d4 ── commit ── commit ── PR → (task 1)
  │
  ├── auto/e5f6g7h8 ── commit ── PR ──────────→ (task 2)
  │
  └── auto/i9j0k1l2 ── commit ── commit ── PR → (task 3)
```

Before creating a branch, cc-taskrunner stashes any uncommitted work in the repo. After the task completes (or fails), it returns to main and restores the stash. Your in-progress work is never clobbered.

If a task produces no commits (e.g., a research/analysis task), the empty branch is cleaned up automatically.

## Writing Good Task Prompts

### Do

- **Be specific about file paths.** "Read `src/services/quota.ts`" not "find the quota code"
- **State completion criteria.** What does "done" look like? Tests passing? File created?
- **Include context.** Each task is a fresh session with no memory of previous tasks
- **Say what NOT to do.** "Do NOT modify source files" prevents scope creep
- **End with "Commit your work."** Otherwise the task may complete with uncommitted changes

### Don't

- **Don't assume shared context.** Fresh session, no conversation history
- **Don't queue ambiguous tasks.** "Improve the codebase" will produce random changes
- **Don't queue tasks that modify the same files.** They'll create merge conflicts
- **Don't skip reading the target code first.** Bad prompt = wasted compute

### Task Sizing

| Size | Turns | Example |
|------|-------|---------|
| Small | 5-10 | Create a README, simple rename, count lines |
| Medium | 15-20 | Write test suite, add a component, document an API |
| Large | 20-25 | Multi-file feature, cross-module refactor |
| Too big | 25+ | Split into smaller tasks |

## Authority Levels

Tasks have an `authority` field that controls branch behavior:

| Authority | Branch? | PR? | Use for |
|-----------|---------|-----|---------|
| `operator` | No | No | Your own tasks, run on current branch |
| `auto_safe` | Yes | Yes | Tests, docs, research, refactors |

`operator` tasks run directly on whatever branch you're on — useful when you want Claude to work in your current context. `auto_safe` tasks get full branch isolation and automatic PRs.

## What NOT to Queue

- Production deploys (safety hooks will block these anyway)
- Database migrations (irreversible)
- Auth/payment/secrets changes (security-sensitive)
- Architectural decisions (needs human judgment)
- Anything that deletes user data

## Origin

cc-taskrunner was extracted from AEGIS, a production autonomous AI agent system (Stackbilt internal infrastructure) that has executed 236+ tasks across 16 repositories. The safety architecture, branch lifecycle, and mission brief patterns were developed through real production incidents — not theoretical design.

## License

Apache License 2.0 — Copyright 2026 Stackbilt LLC

See [LICENSE](LICENSE) for details.
