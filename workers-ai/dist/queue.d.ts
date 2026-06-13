import type { CcTask } from './types.js';
/** Atomically claims the next pending workers_ai task. Returns null if none available. */
export declare function claimNextTask(db: D1Database): Promise<CcTask | null>;
export declare function completeTask(db: D1Database, id: string, result: string, exitCode: number, failureKind: string | null): Promise<void>;
export declare function failTask(db: D1Database, id: string, error: string): Promise<void>;
