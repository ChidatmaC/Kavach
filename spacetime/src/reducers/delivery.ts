// Outbox (D6), verifications, drills and briefings.
import { SenderError, t } from 'spacetimedb/server';
import { Timestamp } from 'spacetimedb';
import spacetimedb from '../tables';
import {
  appName, at, canAlertContact, familyRecipients, messagePerson, oneOf, queueAgent, queueMessage,
  requirePersonAccess, requireService, senderPerson, serviceRole, timers,
} from '../lib';

const OUT_CHANNELS = ['imessage', 'sms', 'rcs', 'whatsapp', 'push'] as const;
const KINDS = ['reply', 'family_alert', 'checkin', 'verification', 'relay', 'briefing', 'practice', 'system'] as const;

/**
 * Agents, voice and photon write every outgoing message here. Family alerts are refused
 * unless the contact accepted, and when sharing is paused unless Critical + override +
 * emergency contact (spec 6 and 8).
 */
export const enqueue_outbox = spacetimedb.reducer(
  {
    to_e164: t.string(),
    channel: t.string(),
    kind: t.string(),
    body: t.string(),
    priority: t.string(),
    related_incident_id: t.u64(),
    recipient_contact_id: t.u64(),
    group_key: t.string(),
  },
  (ctx, a) => {
    requireService(ctx, 'agents', 'photon', 'voice');
    oneOf('channel', a.channel, OUT_CHANNELS);
    oneOf('kind', a.kind, KINDS);
    const priority = oneOf('priority', a.priority, ['urgent', 'normal']) as 'urgent' | 'normal';
    if (a.kind === 'family_alert') {
      const c = ctx.db.contact.id.find(a.recipient_contact_id);
      if (!c) throw new SenderError('family alerts need recipient_contact_id');
      const p = ctx.db.person.id.find(c.person_id)!;
      const inc = a.related_incident_id ? ctx.db.incident.id.find(a.related_incident_id) : null;
      if (!canAlertContact(p, c, inc?.severity ?? '')) {
        throw new SenderError('family alert refused: no consent or sharing is paused');
      }
      if (c.phone_e164 !== a.to_e164) throw new SenderError('to_e164 must match the contact');
    }
    queueMessage(ctx, {
      to_e164: a.to_e164, channel: a.channel, kind: a.kind, body: a.body, priority,
      related_incident_id: a.related_incident_id, recipient_contact_id: a.recipient_contact_id, group_key: a.group_key,
    });
  }
);

export const mark_outbox_status = spacetimedb.reducer(
  { outbox_id: t.u64(), status: t.string(), channel: t.string() },
  (ctx, { outbox_id, status, channel }) => {
    requireService(ctx, 'photon', 'agents');
    oneOf('status', status, ['queued', 'sending', 'sent', 'failed']);
    const row = ctx.db.outbox.id.find(outbox_id);
    if (!row) throw new SenderError('unknown outbox row');
    if (row.status === 'sent') return; // at-least-once delivery: duplicate protection by id
    const attempts = status === 'sending' ? Math.min(row.attempts + 1, 255) : row.attempts;
    ctx.db.outbox.id.update({
      ...row, status, attempts,
      channel: channel ? oneOf('channel', channel, OUT_CHANNELS) : row.channel,
    });
  }
);

// --- verification ---------------------------------------------------------------

export const start_verification = spacetimedb.reducer(
  { request_key: t.string(), person_id: t.u64(), contact_id: t.u64(), kind: t.string() },
  (ctx, a) => {
    if (!a.request_key) throw new SenderError('request_key required');
    if (ctx.db.verification.request_key.find(a.request_key)) return;
    const p = requirePersonAccess(ctx, a.person_id);
    oneOf('kind', a.kind, ['relay', 'trusted_sender']);
    const c = ctx.db.contact.id.find(a.contact_id);
    if (!c || c.person_id !== p.id) throw new SenderError('unknown contact');
    const t2 = timers(ctx);
    const v = ctx.db.verification.insert({
      id: 0n, request_key: a.request_key, person_id: p.id, contact_id: c.id, kind: a.kind, status: 'pending',
      deadline: new Timestamp(ctx.timestamp.microsSinceUnixEpoch + t2.verifyDeadline), created_at: ctx.timestamp,
    });
    ctx.db.verificationDeadlineJob.insert({ scheduled_id: 0n, scheduled_at: at(ctx, t2.verifyDeadline), verification_id: v.id });
  }
);

/**
 * Photon (relative replied yes/no) or the relative's own app (Trusted Sender push).
 * A denial tells the person and the rest of the family that it was a scam.
 */
export const resolve_verification = spacetimedb.reducer(
  { verification_id: t.u64(), result: t.string() },
  (ctx, { verification_id, result }) => {
    oneOf('result', result, ['confirmed', 'denied']);
    const v = ctx.db.verification.id.find(verification_id);
    if (!v) throw new SenderError('unknown verification');
    const c = ctx.db.contact.id.find(v.contact_id);
    const p = ctx.db.person.id.find(v.person_id);
    if (!c || !p) throw new SenderError('verification is missing its contact');
    if (!serviceRole(ctx)) {
      const me = senderPerson(ctx);
      if (!me || me.id !== c.linked_person_id) throw new SenderError('only the relative can answer');
    }
    if (v.status !== 'pending') return;
    ctx.db.verification.id.update({ ...v, status: result });
    const app = appName(ctx);
    if (result === 'confirmed') {
      messagePerson(ctx, p, 'verification', `${app}: ${c.name} confirmed it's really them. Still, never share codes, even with family.`, 'normal');
    } else {
      messagePerson(ctx, p, 'verification',
        `${app}: ${c.name} says it was NOT them. This is a scam. Hang up or stop replying, and don't send anything.`, 'urgent');
      for (const other of familyRecipients(ctx, p, 'high')) {
        if (other.id === c.id) continue;
        queueMessage(ctx, {
          to_e164: other.phone_e164, channel: other.channel, kind: 'family_alert', priority: 'normal',
          recipient_contact_id: other.id,
          body: `${app}: Someone pretended to be ${c.name} to reach ${p.display_name}. ${c.name} confirmed it wasn't them. ${p.display_name} is safe and has been told it's a scam.`,
        });
      }
    }
  }
);

// --- drills (practice scams, Stretch) -------------------------------------------------

export const schedule_drill = spacetimedb.reducer(
  { person_id: t.u64(), contact_id: t.u64(), template_key: t.string(), send_at_micros: t.i64() },
  (ctx, a) => {
    const p = ctx.db.person.id.find(a.person_id);
    if (!p) throw new SenderError('unknown person');
    const c = ctx.db.contact.id.find(a.contact_id);
    if (!c || c.person_id !== p.id) throw new SenderError('unknown contact');
    if (!serviceRole(ctx)) {
      const me = senderPerson(ctx);
      if (!me || (me.id !== p.id && me.id !== c.linked_person_id)) throw new SenderError('not allowed');
    }
    if (!p.practice_consent) throw new SenderError('practice consent is off');
    const sendAt = a.send_at_micros < ctx.timestamp.microsSinceUnixEpoch ? ctx.timestamp.microsSinceUnixEpoch : a.send_at_micros;
    const d = ctx.db.drill.insert({
      id: 0n, person_id: p.id, scheduled_by_contact_id: c.id, template_key: a.template_key.slice(0, 40),
      send_at: new Timestamp(sendAt), outcome: 'pending',
    });
    queueAgent(ctx, 'practice', { drill_id: d.id }, sendAt - ctx.timestamp.microsSinceUnixEpoch);
  }
);

export const record_drill_outcome = spacetimedb.reducer(
  { drill_id: t.u64(), outcome: t.string() },
  (ctx, { drill_id, outcome }) => {
    oneOf('outcome', outcome, ['pending', 'checked', 'ignored', 'replied']);
    const d = ctx.db.drill.id.find(drill_id);
    if (!d) throw new SenderError('unknown drill');
    requirePersonAccess(ctx, d.person_id);
    ctx.db.drill.id.update({ ...d, outcome });
  }
);

// --- briefings ---------------------------------------------------------------------

/** Agents: store the weekly briefing and text it to the person. */
export const save_briefing = spacetimedb.reducer(
  { person_id: t.u64(), week_start_micros: t.i64(), summary_text: t.string(), spoken_text: t.string() },
  (ctx, a) => {
    requireService(ctx, 'agents');
    const p = requirePersonAccess(ctx, a.person_id);
    const summary = a.summary_text.slice(0, 1200);
    ctx.db.briefing.insert({
      id: 0n, person_id: p.id, week_start: new Timestamp(a.week_start_micros), summary_text: summary,
      spoken_text: a.spoken_text.slice(0, 2000), created_at: ctx.timestamp,
    });
    queueMessage(ctx, { to_e164: p.phone_e164, channel: 'imessage', kind: 'briefing', body: summary, priority: 'normal' });
  }
);

/** iOS app or admin: generate a briefing now (demo step 9). */
export const request_briefing = spacetimedb.reducer(
  { person_id: t.u64() },
  (ctx, { person_id }) => {
    const p = requirePersonAccess(ctx, person_id);
    queueAgent(ctx, 'briefing', { person_id: p.id });
  }
);
