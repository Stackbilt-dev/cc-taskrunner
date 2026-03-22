# cc-taskrunner

Autonomous task queue for Claude Code with safety hooks, branch isolation, and PR creation.

## Commands
- `./taskrunner.sh` — Run until queue empty
- `./taskrunner.sh --max N` — Run at most N tasks
- `./taskrunner.sh --loop` — Loop forever (poll every 60s)
- `./taskrunner.sh --dry-run` — Preview without executing
- `./taskrunner.sh add "title"` — Add a task to the queue

## Structure
- `taskrunner.sh` — Main script (~580 lines bash + embedded python)
- `hooks/` — Safety hook scripts (block-interactive, safety-gate, syntax-check, deploy)
- `queue.json` — Task queue file (JSON array, gitignored; see queue.example.json)
- `scripts/` — Helper scripts (deploy)
- `plugin/` — Plugin system (agents, commands, safety)

## Conventions
- Bash 4+, Python 3 for JSON manipulation
- All paths relative to script directory
- Tasks use JSON format with id, title, repo, prompt, status fields
- Completion signal: TASK_COMPLETE or TASK_BLOCKED
