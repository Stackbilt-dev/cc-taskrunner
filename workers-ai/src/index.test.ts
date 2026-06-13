import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createWorkersAiRunner } from './index.js';
import type { CcTask } from './types.js';

// ─── Minimal D1Database mock ──────────────────────────────────────────────────

function makeDb(tasks: CcTask[] = []) {
  let claimCalled = false;
  const claimed = new Set<string>();

  return {
    prepare: vi.fn((sql: string) => ({
      first: vi.fn(async () => {
        if (sql.includes('RETURNING')) {
          if (!claimCalled && tasks.length > 0) {
            claimCalled = true;
            const task = tasks[0];
            claimed.add(task.id);
            return task;
          }
          return null;
        }
        return null;
      }),
      bind: vi.fn(function (this: unknown) { return this; }),
      run: vi.fn(async () => ({})),
    })),
  } as unknown as D1Database;
}

// ─── Minimal Ai mock ─────────────────────────────────────────────────────────

function makeAi(response: string) {
  return {
    run: vi.fn(async () => ({ response })),
  } as unknown as Ai;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

describe('createWorkersAiRunner', () => {
  it('returns a runner with a run() method', () => {
    const runner = createWorkersAiRunner({ db: makeDb(), ai: makeAi('') });
    expect(typeof runner.run).toBe('function');
  });

  it('returns zero counts when queue is empty', async () => {
    const runner = createWorkersAiRunner({ db: makeDb([]), ai: makeAi('done\nTASK_COMPLETE') });
    const result = await runner.run();
    expect(result).toEqual({ processed: 0, completed: 0, failed: 0 });
  });

  it('marks task completed when TASK_COMPLETE signal present', async () => {
    const task: CcTask = {
      id: 'task-001',
      title: 'Test task',
      repo: 'test-repo',
      prompt: 'Do something',
      category: 'research',
      completion_signal: null,
    };
    const db = makeDb([task]);
    const runner = createWorkersAiRunner({ db, ai: makeAi('Result here.\nTASK_COMPLETE') });
    const result = await runner.run();
    expect(result.processed).toBe(1);
    expect(result.completed).toBe(1);
    expect(result.failed).toBe(0);
  });

  it('marks task failed when no completion signal', async () => {
    const task: CcTask = {
      id: 'task-002',
      title: 'Incomplete task',
      repo: 'test-repo',
      prompt: 'Do something',
      category: 'research',
      completion_signal: null,
    };
    const db = makeDb([task]);
    const runner = createWorkersAiRunner({ db, ai: makeAi('I started but did not finish') });
    const result = await runner.run();
    expect(result.processed).toBe(1);
    expect(result.failed).toBe(1);
    expect(result.completed).toBe(0);
  });

  it('respects custom completion_signal', async () => {
    const task: CcTask = {
      id: 'task-003',
      title: 'Custom signal task',
      repo: 'test-repo',
      prompt: 'Do something',
      category: 'research',
      completion_signal: 'DONE',
    };
    const db = makeDb([task]);
    const runner = createWorkersAiRunner({ db, ai: makeAi('Output here.\nDONE') });
    const result = await runner.run();
    expect(result.completed).toBe(1);
  });

  it('respects maxTasksPerRun option', async () => {
    const task: CcTask = {
      id: 'task-004',
      title: 'Single task',
      repo: 'test-repo',
      prompt: 'Do something',
      category: 'research',
      completion_signal: null,
    };
    const db = makeDb([task]);
    const runner = createWorkersAiRunner({
      db, ai: makeAi('TASK_COMPLETE'),
      options: { maxTasksPerRun: 1 },
    });
    const result = await runner.run();
    expect(result.processed).toBeLessThanOrEqual(1);
  });
});
