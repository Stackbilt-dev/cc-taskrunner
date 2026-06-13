import type { RunnerConfig, WorkersAiRunner } from './types.js';
export type { CcTask, RunnerConfig, RunnerOptions, RunResult, WorkersAiRunner } from './types.js';
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
export declare function createWorkersAiRunner(config: RunnerConfig): WorkersAiRunner;
