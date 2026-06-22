# cc-taskrunner

Autonomous task queue for Claude Code with safety hooks, branch isolation, and PR creation.

## Commands
- `./taskrunner.sh` — Run until queue empty
- `./taskrunner.sh --max N` — Run at most N tasks
- `./taskrunner.sh --loop` — Loop forever (poll every 60s)
- `./taskrunner.sh --dry-run` — Preview without executing
- `./taskrunner.sh add "title"` — Add a task to the queue
- `./taskrunner.sh pull --fix-id <uuid>` — Pull a QUEUED fix from CodeBeast D1 into queue.json
- `./taskrunner.sh pull --fix-id <uuid> --dry-run` — Preview D1 row without writing anything

## Key env vars
- `CC_TASK_TIMEOUT` — Watchdog timeout in seconds (default 1500 / 25 min); tasks exceeding this are marked TASK_BLOCKED
- `CLOUDFLARE_API_TOKEN` / `CF_ACCOUNT_ID` / `D1_FIX_QUEUE_DB_ID` — Required for `pull` subcommand

## Structure
- `taskrunner.sh` — Main script (~1150 lines bash + embedded python)
- `hooks/` — Safety hook scripts (block-interactive, safety-gate, syntax-check)
- `queue.json` — Task queue file (JSON array, gitignored; see queue.example.json)
- `repo-aliases.conf` — Repo alias mappings (gitignored; see repo-aliases.example.conf)
- `scripts/` — Helper scripts (deploy, pull-fix.sh, cleanup-branches.sh)
- `plugin/` — Plugin system (agents, commands, safety)

## Conventions
- Bash 4+, Python 3 for JSON manipulation
- All paths relative to script directory
- Tasks use JSON format with id, title, repo, prompt, status fields
- Completion signal: TASK_COMPLETE or TASK_BLOCKED

## OSS Policy

This is a **public infrastructure package** governed by the Stackbilt OSS Infrastructure Package Update Policy.

Rules:
1. **Additive only** — never remove or rename public API without a major version bump
2. **No product logic** — framework patterns and generic utilities only. If a competitor could reconstruct Stackbilt product architecture from this code, it doesn't belong here.
3. **Strict semver** — patch for fixes, minor for new features, major for breaking changes
4. **Tests travel with code** — every public export must have test coverage
5. **Validate at boundaries** — all external API responses validated before returning to consumers
