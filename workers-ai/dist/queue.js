/** Atomically claims the next pending workers_ai task. Returns null if none available. */
export async function claimNextTask(db) {
    const row = await db.prepare(`
    UPDATE cc_tasks
    SET status = 'running', started_at = datetime('now'), session_id = 'workers-ai'
    WHERE id = (
      SELECT id FROM cc_tasks
      WHERE status = 'pending'
        AND executor = 'workers_ai'
        AND authority IN ('auto_safe', 'operator')
      ORDER BY
        CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END ASC,
        created_at ASC
      LIMIT 1
    )
    RETURNING id, title, repo, prompt, category, completion_signal
  `).first();
    return row ?? null;
}
export async function completeTask(db, id, result, exitCode, failureKind) {
    const status = exitCode === 0 ? 'completed' : 'failed';
    await db.prepare(`
    UPDATE cc_tasks
    SET status = ?, result = ?, exit_code = ?, failure_kind = ?,
        completed_at = datetime('now'), updated_at = datetime('now')
    WHERE id = ?
  `).bind(status, result, exitCode, failureKind, id).run();
}
export async function failTask(db, id, error) {
    await db.prepare(`
    UPDATE cc_tasks
    SET status = 'failed', error = ?, failure_kind = 'workers_ai_error',
        exit_code = 1, completed_at = datetime('now'), updated_at = datetime('now')
    WHERE id = ?
  `).bind(error.slice(0, 1000), id).run();
}
