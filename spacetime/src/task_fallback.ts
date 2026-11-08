// Agent task helpers (not registered exports; kept out of the module entry).
import { type Ctx } from './lib';
import { queueTemplateFamilyAlert } from './severity';

export const AGENT_TASK_BUDGET = 20_000_000n; // 20 s (spec 13)

/** Marks a task failed and applies the fallback: template family alert (spec 13). */
export function failAgentTask(ctx: Ctx, taskId: bigint, why: string) {
  const task = ctx.db.agentTask.id.find(taskId);
  if (!task) return;
  ctx.db.agentTask.id.update({ ...task, status: 'failed', finished_at: ctx.timestamp });
  console.warn(`agent task ${task.workflow} #${task.id} failed: ${why}`);
  if (task.workflow === 'family_alert') {
    const payload = JSON.parse(task.payload_json) as { incident_id: number; priority?: 'urgent' | 'normal' };
    queueTemplateFamilyAlert(ctx, BigInt(payload.incident_id), payload.priority ?? 'normal');
  }
}

