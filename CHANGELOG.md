# Changelog

All notable changes to cc-taskrunner will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

## [0.3.0] — 2026-03-11

### Added
- Claude Code plugin for submission to anthropics/claude-code
- Deploy pipeline script (`scripts/deploy.sh`)

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
