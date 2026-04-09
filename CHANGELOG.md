# Changelog

All notable changes to cc-taskrunner will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

## [1.4.0] — 2026-04-09

### Added
- **Project fingerprint injection** — Mission briefs now include a `## Project Context (auto-generated)` section when `charter surface --markdown` is available on PATH. Gives Claude Code an immediate map of routes + schema tables so it doesn't burn turns exploring the codebase. Degrades gracefully if charter is not installed. Opt out via `CC_DISABLE_FINGERPRINT=1`. Output capped at 80 lines to protect the prompt budget.

## [1.3.0] — 2026-03-29

### Fixed
- **Branch conflict resolution** (#14) — branch cleanup now checks both local AND remote refs before creating task branches. Prior bug: only checked local refs, missed remote-only branches left by worktree cleanup. Stale PRs are auto-closed with comment. Push uses `--force-with-lease` for clean branch reuse.
- **max_turns_exceeded detection** (#15) — Claude's `error_max_turns` JSON subtype is now detected and annotated in result text as `[max_turns_exceeded]`. Consumers can distinguish this from generic failures and decide whether to retry with more turns. Tasks that hit max_turns but created PRs may still be successful.

## [1.2.0] — 2026-03-24

### Added
- Repo alias resolution via `repo-aliases.conf` file (`CC_REPO_ALIASES` env var)
- `CC_REPOS_DIR` env var for configurable base directory for repo lookups
- `.gitattributes` to enforce LF line endings for shell scripts

### Fixed
- CRLF line endings across all shell scripts (caused bash parse errors on Linux/WSL)
- Repo resolution now checks: alias → direct path → `REPOS_DIR/resolved` → `REPOS_DIR/original`

## [1.1.0] — 2026-03-22

### Added
- DAG task dependencies via `blocked_by` field with automatic cascade cancellation
- Issue dedup guard — skips tasks targeting the same GitHub issue as a running/completed task
- Robust completion signal detection — reduces false Exit Code 3 failures
- CLAUDE.md and `.ai/` governance files
- Hero banner and Discord invite badge in README

### Fixed
- Restructured LICENSE for GitHub detection
- OSS standardization: license copyright, branding footer

## [1.0.0] — 2026-03-11

### Added
- Reliability features synced from AEGIS: PR state check, auth probe, LOC guardrail, completion heuristics, circuit breaker, failure classification, preflight
- Claude Code plugin (`plugin/`) for submission to anthropics/claude-code
- Deploy pipeline script (`scripts/deploy.sh`)

### Fixed
- Background output truncation — force line-buffered stdout via `stdbuf`
- Git operation timeouts
- Windows-path directory pollution in `.gitignore`
- Redirect stdin from `/dev/null` to prevent SIGTSTP hang

## [0.2.0] — 2026-03-10

### Fixed
- Only auto-commit task-created files, not pre-existing changes

## [0.1.0] — 2026-03-10

### Added
- Initial release — autonomous task queue for Claude Code
- Safety hooks (block-interactive, safety-gate, syntax-check)
- Branch-per-task isolation with automatic PR creation
- Queue management via JSON file
- `--dry-run`, `--max`, `--loop` flags
