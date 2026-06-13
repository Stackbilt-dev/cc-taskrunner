import type { CcTask, RunnerOptions } from './types.js';

const DEFAULT_MODEL = '@cf/meta/llama-4-scout-17b-16e-instruct';
const DEFAULT_FALLBACK = '@cf/meta/llama-3.1-70b-instruct';
const DEFAULT_MAX_RESULT_CHARS = 4000;

const DEFAULT_SYSTEM_PROMPT = `You are an autonomous task executor. Complete the assigned task precisely and thoroughly.

When your work is done, output TASK_COMPLETE on its own line at the end.
If you cannot complete the task (ambiguous instructions, missing context, or outside your capabilities), output TASK_BLOCKED followed by a one-sentence reason.
Do not ask clarifying questions. Work with what you have.`;

export interface ExecutionResult {
  text: string;
  exitCode: number;
  failureKind: string | null;
}

export async function executeTask(
  ai: Ai,
  task: CcTask,
  options: RunnerOptions = {},
): Promise<ExecutionResult> {
  const model = options.model ?? DEFAULT_MODEL;
  const fallback = options.fallbackModel ?? DEFAULT_FALLBACK;
  const maxChars = options.maxResultChars ?? DEFAULT_MAX_RESULT_CHARS;
  const systemPrompt = options.systemPrompt ?? DEFAULT_SYSTEM_PROMPT;

  const messages = [
    { role: 'system' as const, content: systemPrompt },
    { role: 'user' as const, content: task.prompt },
  ];

  let text = '';
  try {
    const result = await (ai as Ai).run(
      model as Parameters<Ai['run']>[0],
      { messages, max_tokens: 4096 } as AiTextGenerationInput,
    );
    text = extractText(result);
  } catch {
    const result = await (ai as Ai).run(
      fallback as Parameters<Ai['run']>[0],
      { messages, max_tokens: 4096 } as AiTextGenerationInput,
    );
    text = extractText(result);
  }

  const completionSignal = task.completion_signal ?? 'TASK_COMPLETE';
  const completed = text.includes(completionSignal) || text.includes('TASK_COMPLETE');
  const blocked = text.includes('TASK_BLOCKED');

  return {
    text: text.slice(0, maxChars),
    exitCode: completed ? 0 : 1,
    failureKind: blocked ? 'task_blocked' : (!completed ? 'no_completion_signal' : null),
  };
}

function extractText(result: unknown): string {
  if (typeof result === 'string') return result;
  if (result && typeof result === 'object') {
    const r = result as Record<string, unknown>;
    if (typeof r.response === 'string') return r.response;
    if (typeof r.text === 'string') return r.text;
  }
  return '';
}
