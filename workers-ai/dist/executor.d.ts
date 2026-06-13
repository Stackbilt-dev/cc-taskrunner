import type { CcTask, RunnerOptions } from './types.js';
export interface ExecutionResult {
    text: string;
    exitCode: number;
    failureKind: string | null;
}
export declare function executeTask(ai: Ai, task: CcTask, options?: RunnerOptions): Promise<ExecutionResult>;
