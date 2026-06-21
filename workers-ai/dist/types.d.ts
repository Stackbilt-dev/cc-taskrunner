export interface CcTask {
    id: string;
    title: string;
    repo: string;
    prompt: string;
    category: string;
    completion_signal: string | null;
}
export interface RunnerConfig {
    db: D1Database;
    ai: Ai;
    options?: RunnerOptions;
}
export interface RunnerOptions {
    /** Primary model. Default: '@cf/zai-org/glm-5.2' */
    model?: string;
    /** Fallback model if primary fails. Default: '@cf/meta/llama-4-scout-17b-16e-instruct' */
    fallbackModel?: string;
    /** Max tasks to claim and execute per run() call. Default: 3 */
    maxTasksPerRun?: number;
    /** Max characters stored in result column. Default: 4000 */
    maxResultChars?: number;
    /** Override the default system prompt injected before every task. */
    systemPrompt?: string;
}
export interface RunResult {
    processed: number;
    completed: number;
    failed: number;
}
export interface WorkersAiRunner {
    run(): Promise<RunResult>;
}
