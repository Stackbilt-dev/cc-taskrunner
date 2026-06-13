import { claimNextTask, completeTask, failTask } from './queue.js';
import { executeTask } from './executor.js';
import type {
  RunnerConfig,
  RunnerOptions,
  RunResult,
  WorkersAiRunner,
} from './types.js';

export type { CcTask, RunnerConfig, RunnerOptions, RunResult, WorkersAiRunner } from './types.js';

const DEFAULT_MAX_TASKS = 3;

/**
 * Creates a Workers AI task runner that claims and executes pending cc_tasks
 * from a D1 database using Cloudflare's AI binding (free inference).
 *
 * Designed for: research, analysis, content generation, wiki writes.
 * Not designed for: tasks requiring git operations, file edits, or shell access
 * (use the cc-taskrunner bash script + Claude Code for those).
 *
 * @example
 * // In your Cloudflare Worker scheduled handler:
 * export default {
 *   async scheduled(event, env, ctx) {
 *     const runner = createWorkersAiRunner({ db: env.DB, ai: env.AI });
 *     await runner.run();
 *   }
 * }
 */
export function createWorkersAiRunner(config: RunnerConfig): WorkersAiRunner {
  const { db, ai, options = {} } = config;
  const maxTasksPerRun = options.maxTasksPerRun ?? DEFAULT_MAX_TASKS;

  return {
    async run(): Promise<RunResult> {
      const result: RunResult = { processed: 0, completed: 0, failed: 0 };

      for (let i = 0; i < maxTasksPerRun; i++) {
        const task = await claimNextTask(db);
        if (!task) break;

        result.processed++;

        try {
          const execution = await executeTask(ai, task, options as RunnerOptions);
          await completeTask(db, task.id, execution.text, execution.exitCode, execution.failureKind);

          if (execution.exitCode === 0) {
            result.completed++;
          } else {
            result.failed++;
          }

          console.log(`[workers-ai-runner] ${task.id.slice(0, 8)} → ${execution.exitCode === 0 ? 'completed' : 'failed'} (${task.category})`);
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          await failTask(db, task.id, msg);
          result.failed++;
          console.error(`[workers-ai-runner] ${task.id.slice(0, 8)} threw:`, msg);
        }
      }

      return result;
    },
  };
}
