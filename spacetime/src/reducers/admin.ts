// Admin-only reducers used by scripts/seed.ts and scripts/demo_reset.ts.
import { SenderError, t } from 'spacetimedb/server';
import spacetimedb from '../tables';
import { type Ctx, LABEL_THRESHOLD, ZERO_TS, e164, normalizeValue, oneOf, requireService } from '../lib';


/** Wipes all application data (keeps service accounts and schedule ticks). */
export const admin_reset = spacetimedb.reducer(ctx => {
  if (requireService(ctx, 'admin') !== 'admin') throw new SenderError('admin only');
  for (const r of ctx.db.outbox.iter()) ctx.db.outbox.id.delete(r.id);
  for (const r of ctx.db.signInChallenge.iter()) ctx.db.signInChallenge.id.delete(r.id);
  for (const r of ctx.db.signInRequestLog.iter()) ctx.db.signInRequestLog.id.delete(r.id);
  for (const r of ctx.db.recoveryStep.iter()) ctx.db.recoveryStep.id.delete(r.id);
  for (const r of ctx.db.incident.iter()) ctx.db.incident.id.delete(r.id);
  for (const r of ctx.db.messageCheck.iter()) ctx.db.messageCheck.id.delete(r.id);
  for (const r of ctx.db.inboundMessage.iter()) ctx.db.inboundMessage.id.delete(r.id);
  for (const r of ctx.db.verification.iter()) ctx.db.verification.id.delete(r.id);
  for (const r of ctx.db.briefing.iter()) ctx.db.briefing.id.delete(r.id);
  for (const r of ctx.db.reportVote.iter()) ctx.db.reportVote.id.delete(r.id);
  for (const r of ctx.db.reportEvidence.iter()) ctx.db.reportEvidence.id.delete(r.id);
  for (const r of ctx.db.communityReport.iter()) ctx.db.communityReport.id.delete(r.id);
  for (const r of ctx.db.campaign.iter()) ctx.db.campaign.id.delete(r.id);
  for (const r of ctx.db.contact.iter()) ctx.db.contact.id.delete(r.id);
  for (const r of ctx.db.optOut.iter()) ctx.db.optOut.phone_e164.delete(r.phone_e164);
  for (const r of ctx.db.verificationDeadlineJob.iter()) ctx.db.verificationDeadlineJob.scheduled_id.delete(r.scheduled_id);
  for (const r of ctx.db.alertDeadlineJob.iter()) ctx.db.alertDeadlineJob.scheduled_id.delete(r.scheduled_id);
  for (const r of ctx.db.alertRequest.iter()) ctx.db.alertRequest.id.delete(r.id);
  for (const r of ctx.db.questionnaireReminderJob.iter()) ctx.db.questionnaireReminderJob.scheduled_id.delete(r.scheduled_id);
  for (const r of ctx.db.checkinJob.iter()) ctx.db.checkinJob.scheduled_id.delete(r.scheduled_id);
  for (const r of ctx.db.agentJob.iter()) ctx.db.agentJob.scheduled_id.delete(r.scheduled_id);
  for (const r of ctx.db.agentTask.iter()) ctx.db.agentTask.id.delete(r.id);
  for (const r of ctx.db.agentTaskTimeoutJob.iter()) ctx.db.agentTaskTimeoutJob.scheduled_id.delete(r.scheduled_id);
  // Persons keep their app binding (owner_hex) so phones stay signed in across resets.
  for (const p of ctx.db.person.iter()) {
    ctx.db.person.id.update({
      ...p, sharing_paused: false, recovery_watch_until: ZERO_TS, campaign_watch_until: ZERO_TS,
      watch_campaign_id: 0n, watch_caller_e164: '',
    });
  }
});

export const admin_seed_person = spacetimedb.reducer(
  {
    phone: t.string(), name: t.string(), critical_overrides_pause: t.bool(),
    tz_offset_minutes: t.i32(), family_code_word: t.string(),
  },
  (ctx, a) => {
    requireService(ctx, 'admin');
    e164('phone', a.phone);
    const existing = ctx.db.person.phone_e164.find(a.phone);
    const fields = {
      display_name: a.name, critical_overrides_pause: a.critical_overrides_pause,
      tz_offset_minutes: a.tz_offset_minutes, family_code_word: a.family_code_word,
    };
    if (existing) ctx.db.person.id.update({ ...existing, ...fields });
    else ctx.db.person.insert({
      id: 0n, owner_hex: '', phone_e164: a.phone, accessibility_mode: false, sharing_paused: false, apns_token: '',
      recovery_watch_until: ZERO_TS, campaign_watch_until: ZERO_TS, watch_campaign_id: 0n, watch_caller_e164: '',
      created_at: ctx.timestamp, last_sign_in_at: ZERO_TS, ...fields,
    });
  }
);

export const admin_seed_contact = spacetimedb.reducer(
  {
    person_phone: t.string(), name: t.string(), phone: t.string(), relationship: t.string(), channel: t.string(),
    is_emergency_contact: t.bool(), is_app_user: t.bool(), consent_status: t.string(),
  },
  (ctx, a) => {
    requireService(ctx, 'admin');
    const p = ctx.db.person.phone_e164.find(a.person_phone);
    if (!p) throw new SenderError('seed the person first');
    oneOf('channel', a.channel, ['imessage', 'sms', 'rcs', 'whatsapp']);
    const linked = ctx.db.person.phone_e164.find(a.phone);
    ctx.db.contact.insert({
      id: 0n, person_id: p.id, name: a.name, phone_e164: a.phone, relationship: a.relationship, channel: a.channel,
      is_emergency_contact: a.is_emergency_contact, is_app_user: a.is_app_user, linked_person_id: linked?.id ?? 0n,
      consent_status: a.consent_status,
    });
  }
);

export const admin_seed_campaign = spacetimedb.reducer(
  { slug: t.string(), title: t.string(), tactic_summary: t.string(), sample_text: t.string(), weekly_reports: t.u32() },
  (ctx, a) => {
    requireService(ctx, 'admin');
    if (ctx.db.campaign.slug.find(a.slug)) return;
    ctx.db.campaign.insert({ id: 0n, ...a });
  }
);

function campaignId(ctx: Ctx, slug: string): bigint {
  if (!slug) return 0n;
  const c = ctx.db.campaign.slug.find(slug);
  if (!c) throw new SenderError(`unknown campaign ${slug}`);
  return c.id;
}

/** Seeds a report with N synthetic reporters (votes are "seed:<i>"). */
export const admin_seed_report = spacetimedb.reducer(
  { kind: t.string(), value: t.string(), campaign_slug: t.string(), reporter_count: t.u32() },
  (ctx, a) => {
    requireService(ctx, 'admin');
    oneOf('kind', a.kind, ['number', 'link', 'phrase']);
    const r = ctx.db.communityReport.insert({
      id: 0n, kind: a.kind, value: normalizeValue(a.kind, a.value), campaign_id: campaignId(ctx, a.campaign_slug),
      reporter_count: a.reporter_count, label_visible: a.reporter_count >= LABEL_THRESHOLD, last_reported_at: ctx.timestamp,
    });
    for (let i = 0; i < a.reporter_count; i++) ctx.db.reportVote.insert({ id: 0n, report_id: r.id, voter_key: `seed:${i}` });
  }
);

export const admin_seed_evidence = spacetimedb.reducer(
  {
    source: t.string(), channel: t.string(), sender_e164: t.string(), links: t.array(t.string()),
    claimed_identity: t.string(), tactics: t.array(t.string()), text_redacted: t.string(), verdict: t.string(),
    campaign_slug: t.string(),
  },
  (ctx, a) => {
    requireService(ctx, 'admin');
    ctx.db.reportEvidence.insert({
      id: 0n, report_id: 0n, incident_id: 0n, source: a.source, channel: a.channel, sender_e164: a.sender_e164,
      links: a.links.map(l => normalizeValue('link', l)), claimed_identity: a.claimed_identity, tactics: a.tactics,
      text_redacted: a.text_redacted, verdict: a.verdict, campaign_id: campaignId(ctx, a.campaign_slug),
      created_at: ctx.timestamp,
    });
  }
);

/** Full wipe for automated tests: like admin_reset, but also deletes persons (unbinds apps). */
export const admin_wipe = spacetimedb.reducer(ctx => {
  requireService(ctx, 'admin');
  for (const p of ctx.db.person.iter()) ctx.db.person.id.delete(p.id);
  for (const r of ctx.db.signInChallenge.iter()) ctx.db.signInChallenge.id.delete(r.id);
  for (const r of ctx.db.signInRequestLog.iter()) ctx.db.signInRequestLog.id.delete(r.id);
});

/** Sets a report's reporter count (creating the report if needed), e.g. to mark a known scam caller. */
export const admin_set_report = spacetimedb.reducer(
  { kind: t.string(), value: t.string(), campaign_slug: t.string(), reporter_count: t.u32() },
  (ctx, a) => {
    requireService(ctx, 'admin');
    oneOf('kind', a.kind, ['number', 'link', 'phrase']);
    const value = normalizeValue(a.kind, a.value);
    if (a.kind === 'number') e164('value', value);
    const campaign = campaignId(ctx, a.campaign_slug);
    let r = [...ctx.db.communityReport.by_kind_value.filter([a.kind, value])][0];
    if (!r) {
      r = ctx.db.communityReport.insert({
        id: 0n, kind: a.kind, value, campaign_id: campaign, reporter_count: 0, label_visible: false,
        last_reported_at: ctx.timestamp,
      });
    }
    const votes = [...ctx.db.reportVote.iter()].filter(v => v.report_id === r!.id).length;
    for (let i = votes; i < a.reporter_count; i++) ctx.db.reportVote.insert({ id: 0n, report_id: r.id, voter_key: `admin:${i}` });
    ctx.db.communityReport.id.update({
      ...r, reporter_count: Math.max(a.reporter_count, votes), label_visible: Math.max(a.reporter_count, votes) >= LABEL_THRESHOLD,
      campaign_id: r.campaign_id || campaign, last_reported_at: ctx.timestamp,
    });
  }
);
