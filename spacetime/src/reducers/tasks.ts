// Agent task queue: the agent service polls svc_agent_task, claims and completes tasks.
import { SenderError, t } from 'spacetimedb/server';
import spacetimedb from '../tables';
import { requireService } from '../lib';
import { failAgentTask } from '../task_fallback';

/** Agents: claim a queued task. Fails (so another poller skips it) if already claimed. */
export const claim_agent_task = spacetimedb.reducer(
  { task_id: t.u64() },
  (ctx, { task_id }) => {
    requireService(ctx, 'agents');
    const task = ctx.db.agentTask.id.find(task_id);
    if (!task) throw new SenderError('unknown task');
    if (task.status !== 'queued') throw new SenderError(`task is ${task.status}`);
    ctx.db.agentTask.id.update({ ...task, status: 'running', attempts: Math.min(task.attempts + 1, 255), claimed_at: ctx.timestamp });
  }
);

/** Agents: finish a claimed task. ok=false triggers the fallback. */
export const complete_agent_task = spacetimedb.reducer(
  { task_id: t.u64(), ok: t.bool(), error: t.string() },
  (ctx, { task_id, ok, error }) => {
    requireService(ctx, 'agents');
    const task = ctx.db.agentTask.id.find(task_id);
    if (!task) throw new SenderError('unknown task');
    if (task.status === 'done' || task.status === 'failed') return;
    if (ok) ctx.db.agentTask.id.update({ ...task, status: 'done', finished_at: ctx.timestamp });
    else failAgentTask(ctx, task.id, error.slice(0, 200) || 'agent error');
  }
);
