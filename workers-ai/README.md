# @stackbilt/workers-ai-taskrunner

Cloudflare Workers AI native executor for cc-taskrunner task queues. Claims and executes `cc_tasks` from a D1 database using CF's free AI binding — no local machine, no Claude CLI required.

## Install

```bash
npm install @stackbilt/workers-ai-taskrunner
```

Peer dependencies: `@cloudflare/workers-types >=4`, `@stackbilt/llm-providers >=1.16.0`

## Quick Start

```typescript
import { createWorkersAiRunner } from '@stackbilt/workers-ai-taskrunner';

export default {
  async scheduled(event, env, ctx) {
    const runner = createWorkersAiRunner({ db: env.DB, ai: env.AI });
    const result = await runner.run();
    console.log(`Processed ${result.processed}, completed ${result.completed}, failed ${result.failed}`);
  }
}
```

## API Reference

### `createWorkersAiRunner(config: RunnerConfig): WorkersAiRunner`

#### `RunnerConfig`

| Field | Type | Description |
|-------|------|-------------|
| `db` | `D1Database` | Cloudflare D1 binding |
| `ai` | `Ai` | Cloudflare AI binding |
| `options` | `RunnerOptions` | Optional configuration |

#### `RunnerOptions`

| Field | Type | Default |
|-------|------|---------|
| `model` | `string` | `@cf/meta/llama-4-scout-17b-16e-instruct` |
| `maxTasksPerRun` | `number` | `3` |
| `maxResultChars` | `number` | `4000` |
| `systemPrompt` | `string` | Built-in executor prompt |

#### `RunResult`

```typescript
{ processed: number; completed: number; failed: number }
```

## D1 Schema

```sql
CREATE TABLE cc_tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  repo TEXT NOT NULL,
  prompt TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'research',
  executor TEXT NOT NULL DEFAULT 'workers_ai',
  status TEXT NOT NULL DEFAULT 'pending',
  priority INTEGER NOT NULL DEFAULT 50,
  completion_signal TEXT,       -- custom signal, defaults to TASK_COMPLETE
  result TEXT,
  exit_code INTEGER,
  failure_kind TEXT,
  session_id TEXT,
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

The daemon schema (aegis-daemon) is a superset — compatible out of the box.

## Task Lifecycle

Tasks flow: `pending` → `running` → `completed` | `failed`

- **Claim**: Atomic `UPDATE ... WHERE id = (SELECT ... LIMIT 1) RETURNING *` — prevents double-execution
- **Complete**: LLM output must end with `TASK_COMPLETE` (or custom `completion_signal`)
- **Blocked**: Output ends with `TASK_BLOCKED <reason>` — sets `failure_kind=task_blocked` (not an error; task was out of scope for the model)
- **Error**: Unhandled exception → `failure_kind=workers_ai_error`

## Design Constraints

**Use for**: research, analysis, content generation, wiki writes — anything where the LLM output IS the deliverable.

**Do not use for**: git operations, file edits, shell execution, or anything requiring repo access. Use the [cc-taskrunner bash script](../scripts/taskrunner.sh) + Claude Code for those.

## LLM Routing

All inference goes through `@stackbilt/llm-providers` (`CloudflareProvider`) — no bolted-in `ai.run()` calls. This ensures consistent response normalization, usage tracking, and resiliency across the Stackbilt ecosystem.

## License

Apache-2.0
