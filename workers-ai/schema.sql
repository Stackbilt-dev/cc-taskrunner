-- Minimal D1 schema for @cc-taskrunner/workers-ai
-- Apply once: wrangler d1 execute <db-name> --remote --file=schema.sql
--
-- If you already have a cc_tasks table with compatible columns, skip this.
-- The executor column and workers_ai value are the only hard requirement.

CREATE TABLE IF NOT EXISTS cc_tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  repo TEXT NOT NULL DEFAULT '',
  prompt TEXT NOT NULL,
  executor TEXT NOT NULL DEFAULT 'claude_code'
    CHECK (executor IN ('claude_code', 'workers_ai')),
  authority TEXT NOT NULL DEFAULT 'auto_safe'
    CHECK (authority IN ('auto_safe', 'operator', 'proposed')),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'completed', 'failed')),
  category TEXT NOT NULL DEFAULT 'research'
    CHECK (category IN ('docs', 'tests', 'research', 'bugfix', 'feature', 'refactor', 'deploy')),
  priority TEXT NOT NULL DEFAULT 'medium'
    CHECK (priority IN ('high', 'medium', 'low')),
  completion_signal TEXT,
  result TEXT,
  exit_code INTEGER,
  failure_kind TEXT,
  error TEXT,
  session_id TEXT,
  created_by TEXT NOT NULL DEFAULT 'system',
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_cc_tasks_executor_status
  ON cc_tasks(executor, status, priority, created_at);
