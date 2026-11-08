// Rule-based severity (D2, spec section 8). The LLM never sets or lowers severity.
import {
  type Ctx, type IncidentRow, type PersonRow,
  appName, at, familyGroupKey, familyRecipients, messagePerson, nextMorning,
  queueAgent, queueMessage, timers, tsAfter, voteReport,
} from './lib';
import { recoveryStepsFor } from './recovery';

export const QUESTION_IDS = ['q_identity', 'q_ask', 'q_shared', 'q_secrecy', 'q_help'] as const;
/** Extra, optional answer keys: q_engaged ("no" when declined/blocked), q_summary (free text). */
export const EXTRA_KEYS = ['q_engaged', 'q_summary'] as const;
export const SHARED_ITEMS = [
  'code', 'pin', 'password', 'card', 'gift_card', 'money', 'remote_app', 'personal_details', 'link', 'nothing',
] as const;
const CRITICAL_ITEMS = ['code', 'pin', 'password', 'card', 'gift_card', 'money', 'remote_app'];
const HIGH_ITEMS = ['personal_details', 'link'];
const LEVEL_RANK: Record<string, number> = { '': 0, low: 1, medium: 2, high: 3, critical: 4 };

export type Answers = Partial<Record<string, string>>;

/** Rules table, evaluated top to bottom. Returns "" when there is not enough to decide. */
export function computeSeverity(answers: Answers, shared: string[]): string {
  if (shared.some(s => CRITICAL_ITEMS.includes(s))) return 'critical';
  if (shared.some(s => HIGH_ITEMS.includes(s)) || answers.q_ask === 'agreed') return 'high';
  if (answers.q_engaged === 'no') return 'low';
  if (answers.q_shared !== undefined) {
    // Shared nothing. They engaged if they were asked for something or pressured.
    const engaged = answers.q_ask === 'yes' || answers.q_secrecy === 'yes' || answers.q_engaged === 'yes';
    return engaged ? 'medium' : 'low';
  }
  return '';
}

export function rank(level: string): number {
  return LEVEL_RANK[level] ?? 0;
}

const ITEM_WORDS: Record<string, string> = {
  code: 'a security code', pin: 'a PIN', password: 'a password', card: 'card details',
  gift_card: 'gift card numbers', money: 'money', remote_app: 'an app install',
  personal_details: 'personal details', link: 'a tapped link',
};

export function sharedWords(shared: string[]): string {
  const words = shared.filter(s => s !== 'nothing').map(s => ITEM_WORDS[s] ?? s);
  if (words.length === 0) return 'nothing';
  if (words.length === 1) return words[0];
  return `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`;
}

/** Template family alert, used when the model is unavailable (spec 13 fallback). */
export function templateFamilyAlert(ctx: Ctx, p: PersonRow, inc: IncidentRow): string {
  const who = inc.claimed_identity ? `someone claiming to be ${inc.claimed_identity}` : 'a likely scammer';
  const level = inc.severity === 'critical' ? 'URGENT: ' : '';
  const tactics = inc.tactics.length ? ` They used: ${inc.tactics.slice(0, 3).join(', ').replace(/_/g, ' ')}.` : '';
  const shared = sharedWords(inc.shared_items);
  const first = inc.severity === 'critical'
    ? 'Please call them now and help them call their bank or carrier.'
    : 'Please check in with a call today.';
  const body = `${level}${appName(ctx)}: ${p.display_name} was contacted by ${who}.${tactics} They may have shared ${shared}. ${first} A kind way to start: "I heard about that call, want to go through it together?" Reply "I'm calling" if you're on it.`;
  return body.slice(0, 600);
}

function insertRecoverySteps(ctx: Ctx, inc: IncidentRow, critical: boolean) {
  const existing = new Set([...ctx.db.recoveryStep.incident_id.filter(inc.id)].map(s => s.step_key));
  let order = existing.size;
  for (const s of recoveryStepsFor(inc.shared_items, critical)) {
    if (existing.has(s.key)) continue;
    ctx.db.recoveryStep.insert({
      id: 0n, incident_id: inc.id, step_key: s.key, priority: s.priority, sort_order: order++, done: false,
    });
  }
}

function countCaller(ctx: Ctx, inc: IncidentRow) {
  if (!inc.caller_e164) return;
  const voter = inc.person_id ? `p:${inc.person_id}` : `i:${inc.id}`;
  voteReport(ctx, 'number', inc.caller_e164, voter, inc.campaign_id);
}

/** Feed the incident into the community corpus (section 7a feedback loop). */
function addIncidentEvidence(ctx: Ctx, inc: IncidentRow) {
  const text = inc.summary_redacted
    || [inc.claimed_identity && `Caller claimed to be ${inc.claimed_identity}.`,
        inc.tactics.length ? `Tactics: ${inc.tactics.join(', ')}.` : '',
        `Asked for or got: ${sharedWords(inc.shared_items)}.`].filter(Boolean).join(' ');
  const verdict = rank(inc.severity) >= rank('high') ? 'likely_scam' : 'suspicious';
  for (const e of ctx.db.reportEvidence.iter()) {
    if (e.incident_id === inc.id) {
      ctx.db.reportEvidence.id.update({ ...e, text_redacted: text, tactics: inc.tactics, verdict, campaign_id: inc.campaign_id });
      return;
    }
  }
  ctx.db.reportEvidence.insert({
    id: 0n, report_id: 0n, incident_id: inc.id,
    source: inc.entry_point === 'hotline' ? 'hotline' : inc.entry_point === 'imessage' ? 'message' : 'call',
    channel: inc.entry_point === 'imessage' ? 'imessage' : 'call',
    sender_e164: inc.caller_e164, links: [], claimed_identity: inc.claimed_identity,
    tactics: inc.tactics, text_redacted: text,
    verdict,
    campaign_id: inc.campaign_id, created_at: ctx.timestamp,
  });
}

/** Applies the rules and, when the level rises, runs that level's sequence. */
export function applySeverity(ctx: Ctx, incId: bigint, answers: Answers) {
  const inc = ctx.db.incident.id.find(incId);
  if (!inc || inc.status === 'resolved') return;
  const level = computeSeverity(answers, inc.shared_items);
  if (rank(level) <= rank(inc.severity)) return; // only goes up automatically
  const updated = { ...inc, severity: level, status: 'in_progress' };
  ctx.db.incident.id.update(updated);
  runLevel(ctx, updated);
}

function runLevel(ctx: Ctx, inc: IncidentRow) {
  const p = inc.person_id ? ctx.db.person.id.find(inc.person_id) ?? null : null;
  const t = timers(ctx);
  const app = appName(ctx);
  if (inc.severity !== 'low') addIncidentEvidence(ctx, inc);

  switch (inc.severity) {
    case 'critical': {
      if (p) {
        messagePerson(ctx, p, 'reply',
          `${app}: Act now. This was a scam and you shared ${sharedWords(inc.shared_items)}. Open ${app} for your step-by-step list, or call your bank or carrier using the number on your card. You're not in trouble, and we'll help.`,
          'urgent', inc.id);
      }
      insertRecoverySteps(ctx, inc, true);
      if (p) {
        queueAgent(ctx, 'family_alert', { incident_id: inc.id, priority: 'urgent' });
      }
      countCaller(ctx, inc);
      if (p) {
        ctx.db.checkinJob.insert({ scheduled_id: 0n, scheduled_at: at(ctx, t.criticalCheckin), incident_id: inc.id, kind: 'critical_1h' });
        ctx.db.checkinJob.insert({ scheduled_id: 0n, scheduled_at: nextMorning(ctx, p.tz_offset_minutes), incident_id: inc.id, kind: 'critical_morning' });
        const fresh = ctx.db.person.id.find(p.id)!;
        ctx.db.person.id.update({ ...fresh, recovery_watch_until: tsAfter(ctx, t.criticalWatch) });
        messagePerson(ctx, p, 'reply',
          `${app}: When you're ready, we can fill in a report for ReportFraud.ftc.gov (and ic3.gov if it happened online). Reply "report" and we'll prepare the summary.`,
          'normal', inc.id);
      }
      break;
    }
    case 'high': {
      if (p) {
        messagePerson(ctx, p, 'reply',
          `${app}: Be careful. This looks like a scam. You shared ${sharedWords(inc.shared_items)}, which scammers can use to try again or open accounts. Open ${app} for a few simple steps. We'll check in soon.`,
          'normal', inc.id);
      }
      insertRecoverySteps(ctx, inc, false);
      if (p) {
        queueAgent(ctx, 'family_alert', { incident_id: inc.id, priority: 'normal' });
        queueAgent(ctx, 'interview', { incident_id: inc.id, checkin: true }, t.highCheckin);
        const fresh = ctx.db.person.id.find(p.id)!;
        ctx.db.person.id.update({
          ...fresh,
          campaign_watch_until: tsAfter(ctx, t.highWatch),
          watch_campaign_id: inc.campaign_id,
          watch_caller_e164: inc.caller_e164,
        });
      }
      countCaller(ctx, inc);
      break;
    }
    case 'medium': {
      if (p) {
        messagePerson(ctx, p, 'reply',
          `${app}: Likely scam, and you did the right thing by not sharing anything. Tip: real companies never rush you or ask you to keep a call secret. Reply "block" to report this number.`,
          'normal', inc.id);
      }
      countCaller(ctx, inc);
      break;
    }
    case 'low': {
      if (p) messagePerson(ctx, p, 'reply', `${app}: Nice work. Nothing was shared, so you're safe. We'll count it as a win in your weekly briefing.`, 'normal', inc.id);
      if (inc.entry_point === 'report_swipe') countCaller(ctx, inc);
      break;
    }
  }
}

/** Fallback when the family_alert workflow fails: template alert per eligible contact. */
export function queueTemplateFamilyAlert(ctx: Ctx, incId: bigint, priority: 'urgent' | 'normal') {
  const inc = ctx.db.incident.id.find(incId);
  if (!inc || !inc.person_id) return;
  const p = ctx.db.person.id.find(inc.person_id);
  if (!p) return;
  const body = templateFamilyAlert(ctx, p, inc);
  for (const c of familyRecipients(ctx, p, inc.severity)) {
    queueMessage(ctx, {
      to_e164: c.phone_e164, channel: c.channel, kind: 'family_alert', body, priority,
      related_incident_id: inc.id, recipient_contact_id: c.id, group_key: familyGroupKey(p.id, inc.id),
    });
  }
}
