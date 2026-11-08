// Scheduled jobs (spec 6) and the agent-calling procedure (the only outbound HTTP).
import { ScheduleAt } from 'spacetimedb';
import spacetimedb, {
  agentJob, agentTaskTimeoutJob, briefingTick, checkinJob, familyAckJob, purgeTick, verificationDeadlineJob,
} from './tables';
import { ZERO_TS, at, appName, familyRecipients, messagePerson, queueAgent, queueMessage, timers } from './lib';
import { templateFamilyAlert } from './severity';
import { AGENT_TASK_BUDGET, failAgentTask } from './task_fallback';

const HOUR = 3_600_000_000n;
const DAY = 24n * HOUR;

export const init = spacetimedb.init(ctx => {
  ctx.db.briefingTick.insert({ scheduled_id: 0n, scheduled_at: ScheduleAt.interval(HOUR) });
  ctx.db.purgeTick.insert({ scheduled_id: 0n, scheduled_at: ScheduleAt.interval(DAY) });
});

export const verification_deadline = spacetimedb.reducer(
  { onSchedule: verificationDeadlineJob },
  { job: verificationDeadlineJob.rowType },
  (ctx, { job }) => {
    const v = ctx.db.verification.id.find(job.verification_id);
    if (!v || v.status !== 'pending') return;
    ctx.db.verification.id.update({ ...v, status: 'expired' });
    const p = ctx.db.person.id.find(v.person_id);
    const c = ctx.db.contact.id.find(v.contact_id);
    if (p && c) {
      messagePerson(ctx, p, 'verification',
        `${appName(ctx)}: Not confirmed. ${c.name} hasn't answered yet, so treat this as a scam until you reach them on a number you know. Don't send anything.`,
        'urgent');
    }
  }
);

export const family_ack_deadline = spacetimedb.reducer(
  { onSchedule: familyAckJob },
  { job: familyAckJob.rowType },
  (ctx, { job }) => {
    const inc = ctx.db.incident.id.find(job.incident_id);
    if (!inc || inc.family_ack_by !== 0n || inc.status === 'resolved') return;
    const p = ctx.db.person.id.find(inc.person_id);
    if (!p) return;
    const body = `Reminder: ${templateFamilyAlert(ctx, p, inc)}`.slice(0, 600);
    for (const c of familyRecipients(ctx, p, inc.severity)) {
      queueMessage(ctx, {
        to_e164: c.phone_e164, channel: c.channel, kind: 'family_alert', body, priority: 'urgent',
        related_incident_id: inc.id, recipient_contact_id: c.id,
      });
    }
    messagePerson(ctx, p, 'checkin',
      `${appName(ctx)}: We haven't heard back from your family yet. You can call the ${appName(ctx)} hotline any time and we'll walk through the next steps with you.`,
      'urgent', inc.id);
  }
);

export const critical_checkin = spacetimedb.reducer(
  { onSchedule: checkinJob },
  { job: checkinJob.rowType },
  (ctx, { job }) => {
    const inc = ctx.db.incident.id.find(job.incident_id);
    if (!inc || inc.status === 'resolved') return;
    const p = ctx.db.person.id.find(inc.person_id);
    if (!p) return;
    const left = [...ctx.db.recoveryStep.incident_id.filter(inc.id)].filter(s => !s.done && s.priority !== 'this_week').length;
    const body = job.kind === 'critical_morning'
      ? `${appName(ctx)}: Good morning. Checking in after yesterday. ${left ? `You have ${left} steps left in your list.` : 'Your steps are done.'} Did anyone call or text again?`
      : `${appName(ctx)}: Checking in. How are you doing? ${left ? `${left} steps are still open. Want help with the next one?` : 'You finished the urgent steps. Well done.'}`;
    messagePerson(ctx, p, 'checkin', body, 'normal', inc.id);
  }
);

/** Hourly: start each person's briefing at Sunday 6 pm local (spec 6). */
export const briefing_tick_run = spacetimedb.reducer(
  { onSchedule: briefingTick },
  { job: briefingTick.rowType },
  (ctx, _job) => {
    for (const p of ctx.db.person.iter()) {
      const localMs = Number(ctx.timestamp.microsSinceUnixEpoch / 1000n) + p.tz_offset_minutes * 60_000;
      const d = new Date(localMs);
      if (d.getUTCDay() === 0 && d.getUTCHours() === 18) queueAgent(ctx, 'briefing', { person_id: p.id });
    }
  }
);

/** Daily: blank inbound bodies older than 7 days (spec 5, 12). */
export const purge_inbound = spacetimedb.reducer(
  { onSchedule: purgeTick },
  { job: purgeTick.rowType },
  (ctx, _job) => {
    const cutoff = ctx.timestamp.microsSinceUnixEpoch - timers(ctx).purgeAfter;
    for (const m of ctx.db.inboundMessage.iter()) {
      if (m.body && m.received_at.microsSinceUnixEpoch < cutoff) ctx.db.inboundMessage.id.update({ ...m, body: '' });
    }
  }
);

/** A delayed job is due: hand it to the agent service queue with a 20 s pickup/finish budget. */
export const run_agent_job = spacetimedb.reducer(
  { onSchedule: agentJob },
  { job: agentJob.rowType },
  (ctx, { job }) => {
    const task = ctx.db.agentTask.insert({
      id: 0n, workflow: job.workflow, payload_json: job.payload_json, status: 'queued', attempts: 0,
      created_at: ctx.timestamp, claimed_at: ZERO_TS, finished_at: ZERO_TS,
    });
    ctx.db.agentTaskTimeoutJob.insert({ scheduled_id: 0n, scheduled_at: at(ctx, AGENT_TASK_BUDGET), task_id: task.id });
  }
);

/** Spec 13: if the agent service did not finish in time, fail the task and use the fallback. */
export const agent_task_timeout = spacetimedb.reducer(
  { onSchedule: agentTaskTimeoutJob },
  { job: agentTaskTimeoutJob.rowType },
  (ctx, { job }) => {
    const task = ctx.db.agentTask.id.find(job.task_id);
    if (!task || task.status === 'done' || task.status === 'failed') return;
    failAgentTask(ctx, task.id, 'timeout');
  }
);
