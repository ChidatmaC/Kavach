// Scheduled jobs (spec 6) and the agent-calling procedure (the only outbound HTTP).
import { ScheduleAt } from 'spacetimedb';
import spacetimedb, {
  agentJob, agentTaskTimeoutJob, alertDeadlineJob, briefingTick, questionnaireReminderJob, checkinJob, purgeTick, verificationDeadlineJob,
} from './tables';
import { ZERO_TS, at, appName, messagePerson, startedInApp, queueAgent, queueMessage, replyWindow, timers, tsAfter, withReplyPrompt } from './lib';
import { AGENT_TASK_BUDGET, failAgentTask } from './task_fallback';
import { purgeSignIn } from './signin';

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
    const tracked = p ? [...ctx.db.alertRequest.person_id.filter(p.id)].some(r => r.verification_id === v.id) : false;
    if (p && c && !tracked) {
      messagePerson(ctx, p, 'verification',
        `${appName(ctx)}: Not confirmed. ${c.name} hasn't answered yet, so treat this as a scam until you reach them on a number you know. Don't send anything.`,
        'urgent');
    }
  }
);

/**
 * A family reply window ended (help / alert / verify). First miss: remind the family once and warn
 * the protected person. Second miss: mark it unanswered and warn again, naming who to call.
 */
export const alert_deadline = spacetimedb.reducer(
  { onSchedule: alertDeadlineJob },
  { job: alertDeadlineJob.rowType },
  (ctx, { job }) => {
    const req = ctx.db.alertRequest.id.find(job.alert_request_id);
    if (!req || req.status !== 'pending') return;
    const p = ctx.db.person.id.find(req.person_id);
    if (!p) return;
    const app = appName(ctx);
    const contacts = req.recipient_contact_ids.map(id => ctx.db.contact.id.find(id)).filter(c => !!c);
    const names = contacts.map(c => c!.name);
    const who = names.length <= 1 ? (names[0] ?? 'Your family') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
    const verifyName = names[0] ?? 'They';
    const hasnt = names.length === 1 ? "hasn't" : "haven't";

    if (req.reminders_sent === 0) {
      for (const c of contacts) {
        if (req.kind === 'verify') {
          queueMessage(ctx, {
            to_e164: c!.phone_e164, channel: c!.channel, kind: 'verification', priority: 'urgent',
            body: `${app}: Reminder: ${p.display_name} is waiting to hear from you. Did you just message them? Reply YES if it was you, or NO if it wasn't.`,
          });
        } else if (c!.consent_status === 'accepted') {
          queueMessage(ctx, {
            to_e164: c!.phone_e164, channel: c!.channel, kind: 'family_alert', priority: 'urgent',
            related_incident_id: req.incident_id, recipient_contact_id: c!.id, track_reply: false,
            body: withReplyPrompt(`Reminder: ${req.last_body.replace(/^Reminder: /, '')}`.slice(0, 560), p.display_name),
          });
        }
      }
      const warn = req.kind === 'verify'
        ? `${app}: ${verifyName} hasn't confirmed yet. Treat it as a scam until you reach them on a number you already know. Don't send anything.`
        : req.kind === 'help'
          ? `${app}: ${who} ${hasnt} replied yet. If the caller is still on the line, hang up and call ${names[0] ?? 'someone you trust'} yourself.`
          : `${app}: ${who} ${hasnt} replied to the scam alert yet. We sent it again. Please call ${names[0] ?? 'someone you trust'} now.`;
      messagePerson(ctx, p, 'system', warn, 'urgent', req.incident_id);
      const window = replyWindow(ctx, req.kind, req.incident_id ? ctx.db.incident.id.find(req.incident_id)?.severity ?? '' : '');
      ctx.db.alertRequest.id.update({ ...req, reminders_sent: 1, deadline: tsAfter(ctx, window) });
      ctx.db.alertDeadlineJob.insert({ scheduled_id: 0n, scheduled_at: at(ctx, window), alert_request_id: req.id });
      return;
    }

    ctx.db.alertRequest.id.update({ ...req, status: 'unanswered', resolved_at: ctx.timestamp });
    if (req.kind === 'verify') {
      const v = ctx.db.verification.id.find(req.verification_id);
      if (v && v.status === 'pending') ctx.db.verification.id.update({ ...v, status: 'expired' });
      messagePerson(ctx, p, 'verification',
        `${app}: Not confirmed. ${verifyName} never answered, so treat this as a scam. Don't send money, codes or gift cards, and call them on a number you know.`, 'urgent');
    } else {
      const first = contacts[0];
      messagePerson(ctx, p, 'system',
        `${app}: No one in your family has replied. Please call ${first ? `${first.name} at ${first.phone_e164}` : 'someone you trust'} directly. If you shared anything, open ${app} for your next steps.`,
        'urgent', req.incident_id);
    }
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
    purgeSignIn(ctx);
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

// Same wording as the agent's text interview, so a reply by text continues the questionnaire.
const QUESTION_TEXT: Record<string, string> = {
  q_answered: 'Did you answer the call? Reply yes or no.',
  q_identity: 'Who did they say they were? For example: your bank, your grandson, the IRS, or a company.',
  q_ask: 'Did they ask for money, codes, gift cards or personal details? Reply yes or no, or "agreed" if you agreed to pay or call them back.',
  q_shared: 'Did you share or send anything? Pick any that apply: code, PIN, password, card details, gift card numbers, money, an app install, personal details, tapped a link, or nothing.',
  q_secrecy: 'Did they ask you to keep it secret or rush you? Reply yes or no.',
  q_help: 'Do you want help right now? Reply yes or no.',
};
const QUESTION_ORDER = ['q_identity', 'q_ask', 'q_shared', 'q_secrecy', 'q_help'];

/**
 * A questionnaire was started but not finished: remind the person (text + push) with the next
 * question, twice at most. Finished means q_shared is answered (that sets the severity).
 */
export const questionnaire_reminder = spacetimedb.reducer(
  { onSchedule: questionnaireReminderJob },
  { job: questionnaireReminderJob.rowType },
  (ctx, { job }) => {
    const inc = ctx.db.incident.id.find(job.incident_id);
    if (!inc || inc.status === 'resolved' || inc.severity !== '') return;
    const p = ctx.db.person.id.find(inc.person_id);
    if (!p) return;
    const answers = JSON.parse(inc.answers_json || '{}') as Record<string, string>;
    // Call reports start with "Did you answer the call?" (a missed call ends the questions).
    const askAnswered = !!inc.caller_e164 && answers.q_answered === undefined && !QUESTION_ORDER.some(q => answers[q] !== undefined);
    const next = askAnswered ? 'q_answered' : QUESTION_ORDER.find(q => answers[q] === undefined) ?? 'q_shared';
    const n = askAnswered ? 1 : QUESTION_ORDER.indexOf(next) + 1;
    const about = inc.caller_e164 ? `the call from ${inc.caller_e164}` : 'what happened';
    const lead = job.attempt === 1
      ? `You started a report about ${about}. Let's finish it, it takes 2 minutes and helps protect you and others.`
      : `Your report about ${about} still isn't finished. Please answer so we can tell you what to do next.`;
    const where = startedInApp(ctx, inc.id) ? `Open ${appName(ctx)} to finish` : `Reply here or open ${appName(ctx)}`;
    messagePerson(ctx, p, 'checkin', `${appName(ctx)}: ${lead} ${where} (${n} of 5): ${QUESTION_TEXT[next]}`.slice(0, 600),
      'normal', inc.id);
    if (job.attempt === 1) {
      ctx.db.questionnaireReminderJob.insert({
        scheduled_id: 0n, scheduled_at: at(ctx, timers(ctx).questionnaireReminder2), incident_id: inc.id, attempt: 2,
      });
    }
  }
);
