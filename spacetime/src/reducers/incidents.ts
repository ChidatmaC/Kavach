// Incidents, interview answers, recovery steps, family acknowledgement.
import { SenderError, t } from 'spacetimedb/server';
import spacetimedb from '../tables';
import {
  ZERO_TS, appName, at, e164, timers, familyGroupKey, familyRecipients, oneOf, queueMessage, redact,
  acknowledgeRequests, requireIncidentAccess, requirePersonAccess, requireService, normalizeValue, findReport, queueAgent,
} from '../lib';
import { EXTRA_KEYS, QUESTION_IDS, SHARED_ITEMS, applySeverity, rank, type Answers } from '../severity';

const ENTRY_POINTS = ['report_swipe', 'companion', 'imessage', 'app'] as const;

/**
 * Opens an incident. request_key is a caller-generated unique string (UUID) so the caller
 * can find the new row's id with `SELECT ... WHERE request_key = ...` (reducers return nothing).
 * person_id = 0 is allowed for services only (e.g. an unregistered texter).
 */
export const open_incident = spacetimedb.reducer(
  { request_key: t.string(), person_id: t.u64(), entry_point: t.string(), caller_e164: t.string() },
  (ctx, a) => {
    if (!a.request_key || a.request_key.length > 64) throw new SenderError('request_key required');
    if (ctx.db.incident.request_key.find(a.request_key)) return; // idempotent
    oneOf('entry_point', a.entry_point, ENTRY_POINTS);
    e164('caller_e164', a.caller_e164, true);
    const p = a.person_id === 0n ? (requireService(ctx), null) : requirePersonAccess(ctx, a.person_id);
    // Link to a campaign through the caller number's community report, if any.
    const report = a.caller_e164 ? findReport(ctx, 'number', normalizeValue('number', a.caller_e164)) : null;
    const inc = ctx.db.incident.insert({
      id: 0n, request_key: a.request_key, person_id: a.person_id, entry_point: a.entry_point,
      caller_e164: a.caller_e164, claimed_identity: '', answers_json: '{}', tactics: [], shared_items: [],
      severity: '', status: 'open', family_ack_by: 0n, campaign_id: report?.campaign_id ?? 0n,
      summary_redacted: '', created_at: ctx.timestamp, resolved_at: ZERO_TS,
    });
    if (p) {
      ctx.db.questionnaireReminderJob.insert({
        scheduled_id: 0n, scheduled_at: at(ctx, timers(ctx).questionnaireReminder), incident_id: inc.id, attempt: 1,
      });
    }
    // Demo step 2: opening Call Companion tells the family "X asked for help during a call".
    if (p && a.entry_point === 'companion') {
      for (const c of familyRecipients(ctx, p, '')) {
        queueMessage(ctx, {
          to_e164: c.phone_e164, channel: c.channel, kind: 'family_alert', priority: 'normal',
          related_incident_id: inc.id, recipient_contact_id: c.id, group_key: familyGroupKey(p.id, inc.id),
          body: `${appName(ctx)}: ${p.display_name} asked for help during a call. They're using ${appName(ctx)} now. You might give them a call when you can.`,
        });
      }
    }
  }
);

function parseShared(answer: string): string[] {
  const items = answer.split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
  for (const i of items) oneOf('q_shared item', i, SHARED_ITEMS);
  if (items.includes('nothing') && items.length > 1) throw new SenderError('"nothing" cannot be combined');
  return items.includes('nothing') ? [] : items;
}

/**
 * Saves one interview answer, then applies the severity rules (spec 8).
 * Answers: q_identity free text; q_ask yes|no|agreed; q_shared comma list of
 * code,pin,password,card,gift_card,money,remote_app,personal_details,link | nothing;
 * q_secrecy yes|no; q_help yes|no; q_engaged yes|no; q_summary free text.
 */
export const save_answer = spacetimedb.reducer(
  { incident_id: t.u64(), question_id: t.string(), answer: t.string() },
  (ctx, { incident_id, question_id, answer }) => {
    const { incident } = requireIncidentAccess(ctx, incident_id);
    if (incident.status === 'resolved') throw new SenderError('incident is resolved');
    oneOf('question_id', question_id, [...QUESTION_IDS, ...EXTRA_KEYS]);
    const answers = JSON.parse(incident.answers_json || '{}') as Answers;
    let { shared_items, claimed_identity, summary_redacted } = incident;
    const raw = answer.trim();
    switch (question_id) {
      case 'q_identity':
        claimed_identity = redact(raw).slice(0, 80);
        answers.q_identity = claimed_identity;
        break;
      case 'q_ask':
        answers.q_ask = oneOf('q_ask', raw.toLowerCase(), ['yes', 'no', 'agreed']);
        break;
      case 'q_shared': {
        const items = parseShared(raw);
        // Answers only ever add shared items, so severity can only go up.
        shared_items = [...new Set([...shared_items, ...items])];
        answers.q_shared = items.length ? items.join(',') : 'nothing';
        break;
      }
      case 'q_secrecy':
      case 'q_help':
      case 'q_engaged':
        answers[question_id] = oneOf(question_id, raw.toLowerCase(), ['yes', 'no']);
        break;
      case 'q_summary':
        summary_redacted = redact(raw).slice(0, 500);
        answers.q_summary = 'provided';
        break;
    }
    ctx.db.incident.id.update({
      ...incident, answers_json: JSON.stringify(answers), shared_items, claimed_identity, summary_redacted,
      status: incident.status === 'open' ? 'in_progress' : incident.status,
    });
    applySeverity(ctx, incident_id, answers);
  }
);

/** Agents: attach tactics and campaign found by community search (never severity). */
export const set_incident_context = spacetimedb.reducer(
  { incident_id: t.u64(), tactics: t.array(t.string()), campaign_id: t.u64() },
  (ctx, { incident_id, tactics, campaign_id }) => {
    requireService(ctx, 'agents');
    const inc = ctx.db.incident.id.find(incident_id);
    if (!inc) throw new SenderError('unknown incident');
    const clean = tactics.map(x => x.toLowerCase().replace(/[^a-z_]/g, '').slice(0, 32)).filter(Boolean).slice(0, 8);
    ctx.db.incident.id.update({
      ...inc,
      tactics: [...new Set([...inc.tactics, ...clean])],
      campaign_id: inc.campaign_id || campaign_id,
    });
  }
);

/** The only path that lowers or closes an incident (spec 8). */
export const resolve_incident = spacetimedb.reducer(
  { incident_id: t.u64() },
  (ctx, { incident_id }) => {
    const { incident } = requireIncidentAccess(ctx, incident_id);
    ctx.db.incident.id.update({ ...incident, status: 'resolved', resolved_at: ctx.timestamp });
  }
);

export const mark_step_done = spacetimedb.reducer(
  { step_id: t.u64(), done: t.bool() },
  (ctx, { step_id, done }) => {
    const step = ctx.db.recoveryStep.id.find(step_id);
    if (!step) throw new SenderError('unknown step');
    const { incident } = requireIncidentAccess(ctx, step.incident_id);
    ctx.db.recoveryStep.id.update({ ...step, done });
    const steps = [...ctx.db.recoveryStep.incident_id.filter(incident.id)];
    const urgentLeft = steps.some(s => (s.priority === 'now' || s.priority === 'today') && !s.done);
    if (!urgentLeft && incident.status !== 'resolved' && steps.length > 0) {
      ctx.db.incident.id.update({ ...incident, status: 'resolved', resolved_at: ctx.timestamp });
    }
  }
);

/** Photon: a family contact replied "I'm calling" / "on it". */
export const family_ack = spacetimedb.reducer(
  { incident_id: t.u64(), contact_id: t.u64() },
  (ctx, { incident_id, contact_id }) => {
    requireService(ctx, 'photon', 'agents');
    const inc = ctx.db.incident.id.find(incident_id);
    const c = ctx.db.contact.id.find(contact_id);
    if (!inc || !c || c.person_id !== inc.person_id) throw new SenderError('unknown incident or contact');
    acknowledgeRequests(ctx, c, { incidentId: inc.id });
    if (inc.family_ack_by !== 0n) return;
    ctx.db.incident.id.update({ ...inc, family_ack_by: contact_id });
    const p = ctx.db.person.id.find(inc.person_id)!;
    for (const other of familyRecipients(ctx, p, inc.severity)) {
      if (other.id === c.id) continue;
      queueMessage(ctx, {
        to_e164: other.phone_e164, channel: other.channel, kind: 'relay', priority: 'normal',
        related_incident_id: inc.id, recipient_contact_id: other.id,
        body: `${appName(ctx)}: ${c.name} is calling ${p.display_name} now.`,
      });
    }
  }
);

/** Medium incidents: "Tell my family" on demand (spec 8). */
export const tell_my_family = spacetimedb.reducer(
  { incident_id: t.u64() },
  (ctx, { incident_id }) => {
    const { incident, person } = requireIncidentAccess(ctx, incident_id);
    if (!person) throw new SenderError('incident has no person');
    if (rank(incident.severity) < rank('low')) throw new SenderError('finish the interview first');
    queueAgent(ctx, 'family_alert', { incident_id: incident.id, priority: 'normal', on_demand: true });
  }
);

/**
 * Photon: a family member replied to a help request or scam alert ("OK", "got it", "on it", or any
 * reply in that thread). Resolves their pending help/alert requests and tells the protected person.
 */
export const acknowledge_family_alert = spacetimedb.reducer(
  { contact_id: t.u64() },
  (ctx, { contact_id }) => {
    requireService(ctx, 'photon', 'agents');
    const c = ctx.db.contact.id.find(contact_id);
    if (!c) throw new SenderError('unknown contact');
    acknowledgeRequests(ctx, c, { kinds: ['help', 'alert'] });
  }
);
