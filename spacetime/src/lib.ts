// Shared helpers: auth, redaction, timers, outbox gating, community votes.
import { SenderError, type InferSchema, type ReducerCtx } from 'spacetimedb/server';
import { ScheduleAt, Timestamp } from 'spacetimedb';
import spacetimedb from './tables';

export type Ctx = ReducerCtx<InferSchema<typeof spacetimedb>>;
type PersonRow = NonNullable<ReturnType<Ctx['db']['person']['id']['find']>>;
type ContactRow = NonNullable<ReturnType<Ctx['db']['contact']['id']['find']>>;
type IncidentRow = NonNullable<ReturnType<Ctx['db']['incident']['id']['find']>>;
export type { PersonRow, ContactRow, IncidentRow };

// --- constants (spec section 5) -----------------------------------------------

export const LABEL_THRESHOLD = 3;
export const MAX_BODY = 600;
export const MAX_BRIEFING_BODY = 1200;
const SEC = 1_000_000n;
const MIN = 60n * SEC;
const HOUR = 60n * MIN;
const DAY = 24n * HOUR;
export const ZERO_TS = new Timestamp(0n);

export function isDemo(ctx: Ctx): boolean {
  return (ctx.env.DEMO_MODE ?? '').toLowerCase() === 'true';
}

export function timers(ctx: Ctx) {
  const demo = isDemo(ctx);
  return {
    verifyDeadline: demo ? 60n * SEC : 5n * MIN,
    familyAckDeadline: demo ? 90n * SEC : 10n * MIN,
    highCheckin: demo ? 2n * MIN : HOUR,
    criticalCheckin: demo ? 3n * MIN : HOUR,
    criticalWatch: 30n * DAY,
    highWatch: 14n * DAY,
    weekWindow: 7n * DAY,
    purgeAfter: 7n * DAY,
  };
}

export function appName(ctx: Ctx): string {
  return ctx.env.APP_DISPLAY_NAME ?? 'Kavach';
}

export function now(ctx: Ctx): bigint {
  return ctx.timestamp.microsSinceUnixEpoch;
}

export function tsAfter(ctx: Ctx, delta: bigint): Timestamp {
  return new Timestamp(now(ctx) + delta);
}

export function at(ctx: Ctx, delta: bigint) {
  return ScheduleAt.time(now(ctx) + delta);
}

/** Next 9:00 local time for a person, as an absolute ScheduleAt. */
export function nextMorning(ctx: Ctx, tzOffsetMinutes: number) {
  const offset = BigInt(tzOffsetMinutes) * MIN;
  const local = now(ctx) + offset;
  const dayStart = local - (((local % DAY) + DAY) % DAY);
  let target = dayStart + 9n * HOUR;
  if (target <= local) target += DAY;
  return ScheduleAt.time(target - offset);
}

// --- auth -----------------------------------------------------------------------

export function serviceRole(ctx: Ctx): string | null {
  return ctx.db.serviceAccount.identity.find(ctx.sender)?.role ?? null;
}

export function requireService(ctx: Ctx, ...roles: string[]): string {
  const role = serviceRole(ctx);
  if (!role) throw new SenderError('service identity required');
  if (roles.length && role !== 'admin' && !roles.includes(role)) {
    throw new SenderError(`role ${role} may not call this reducer`);
  }
  return role;
}

export function senderPerson(ctx: Ctx): PersonRow | null {
  const hex = ctx.sender.toHexString();
  for (const p of ctx.db.person.owner_hex.filter(hex)) return p;
  return null;
}

/** The caller is a service, or the app identity that owns this person. */
export function requirePersonAccess(ctx: Ctx, personId: bigint): PersonRow {
  const p = ctx.db.person.id.find(personId);
  if (!p) throw new SenderError('unknown person');
  if (serviceRole(ctx)) return p;
  if (p.owner_hex !== '' && p.owner_hex === ctx.sender.toHexString()) return p;
  throw new SenderError('not your person');
}

export function requireIncidentAccess(ctx: Ctx, incidentId: bigint): { incident: IncidentRow; person: PersonRow | null } {
  const inc = ctx.db.incident.id.find(incidentId);
  if (!inc) throw new SenderError('unknown incident');
  if (inc.person_id === 0n) {
    // Unregistered hotline caller: only services may touch it.
    requireService(ctx);
    return { incident: inc, person: null };
  }
  return { incident: inc, person: requirePersonAccess(ctx, inc.person_id) };
}

// --- validation -------------------------------------------------------------------

export function oneOf(field: string, value: string, allowed: readonly string[]): string {
  if (!allowed.includes(value)) throw new SenderError(`invalid ${field}: ${value}`);
  return value;
}

const E164 = /^\+[1-9]\d{6,14}$/;
export function e164(field: string, value: string, allowEmpty = false): string {
  if (allowEmpty && value === '') return value;
  if (!E164.test(value)) throw new SenderError(`invalid ${field}: must be E.164`);
  return value;
}

// --- redaction (spec 7: never store codes, card or account numbers) ---------------

export function redact(text: string): string {
  return text
    // card numbers: 13-19 digits with optional spaces/dashes
    .replace(/\b(?:\d[ -]?){13,19}\b/g, '[card number]')
    // account / routing numbers: 9-12 digit runs
    .replace(/(?<!\+)\b\d{9,12}\b/g, '[account number]')
    // one-time codes and PINs: standalone 4-8 digit runs (not part of +E.164 or money)
    .replace(/(?<![+\d$.,])\b\d{4,8}\b(?![.,]\d)/g, '[code]')
    .slice(0, 2000);
}

// --- outbox ---------------------------------------------------------------------------

export interface QueueArgs {
  to_e164: string;
  channel: string;
  kind: string;
  body: string;
  priority?: 'urgent' | 'normal';
  related_incident_id?: bigint;
  recipient_contact_id?: bigint;
  group_key?: string;
}

/** Insert a queued outbox row, honoring opt-outs and length limits. Returns false if suppressed. */
export function queueMessage(ctx: Ctx, a: QueueArgs): boolean {
  const limit = a.kind === 'briefing' ? MAX_BRIEFING_BODY : MAX_BODY;
  if (a.body.length === 0 || a.body.length > limit) throw new SenderError(`body must be 1-${limit} chars`);
  if (a.channel !== 'push' && a.to_e164 && ctx.db.optOut.phone_e164.find(a.to_e164) && a.kind !== 'system') {
    return false;
  }
  ctx.db.outbox.insert({
    id: 0n,
    to_e164: a.to_e164,
    group_key: a.group_key ?? '',
    channel: a.channel,
    kind: a.kind,
    body: a.body,
    priority: a.priority ?? 'normal',
    related_incident_id: a.related_incident_id ?? 0n,
    recipient_contact_id: a.recipient_contact_id ?? 0n,
    status: 'queued',
    attempts: 0,
    created_at: ctx.timestamp,
  });
  return true;
}

/** Reply to the protected person on text, plus a push when the app is installed. */
export function messagePerson(ctx: Ctx, p: PersonRow, kind: string, body: string, priority: 'urgent' | 'normal', incidentId = 0n) {
  queueMessage(ctx, { to_e164: p.phone_e164, channel: 'imessage', kind, body, priority, related_incident_id: incidentId });
  if (p.apns_token) {
    queueMessage(ctx, { to_e164: p.phone_e164, channel: 'push', kind, body, priority, related_incident_id: incidentId });
  }
}

/**
 * Family alert gate (spec 8 and 12): only accepted contacts; when sharing is paused,
 * only the emergency contact, only for Critical, only if the person chose the override.
 */
export function canAlertContact(p: PersonRow, c: ContactRow, severity: string): boolean {
  if (c.person_id !== p.id || c.consent_status !== 'accepted') return false;
  if (!p.sharing_paused) return true;
  return severity === 'critical' && p.critical_overrides_pause && c.is_emergency_contact;
}

export function familyRecipients(ctx: Ctx, p: PersonRow, severity: string): ContactRow[] {
  return [...ctx.db.contact.person_id.filter(p.id)].filter(c => canAlertContact(p, c, severity));
}

export function familyGroupKey(personId: bigint, incidentId: bigint): string {
  return `family:${personId}:${incidentId}`;
}

// --- agent jobs ---------------------------------------------------------------------

export function queueAgent(ctx: Ctx, workflow: string, payload: Record<string, unknown>, delay = 0n) {
  ctx.db.agentJob.insert({
    scheduled_id: 0n,
    scheduled_at: at(ctx, delay),
    workflow,
    payload_json: JSON.stringify(payload, (_k, v) => (typeof v === 'bigint' ? Number(v) : v)),
  });
}

// --- community reports (spec 12: one vote per person per value; label at 3) -------------

export function normalizeValue(kind: string, value: string): string {
  const v = value.trim().toLowerCase();
  if (kind === 'link') {
    return v.replace(/^[a-z]+:\/\//, '').replace(/^www\./, '').split(/[/?#]/)[0];
  }
  if (kind === 'phrase') return v.replace(/\s+/g, ' ').slice(0, 200);
  return value.trim();
}

export function findReport(ctx: Ctx, kind: string, value: string) {
  for (const r of ctx.db.communityReport.by_kind_value.filter([kind, value])) return r;
  return null;
}

/** Adds one vote for (kind, value) from voterKey; returns the report id. Idempotent per voter. */
export function voteReport(ctx: Ctx, kind: string, rawValue: string, voterKey: string, campaignId = 0n): bigint {
  const value = normalizeValue(kind, rawValue);
  if (!value) return 0n;
  let r = findReport(ctx, kind, value);
  if (!r) {
    r = ctx.db.communityReport.insert({
      id: 0n, kind, value, campaign_id: campaignId, reporter_count: 0,
      label_visible: false, last_reported_at: ctx.timestamp,
    });
  }
  for (const _v of ctx.db.reportVote.by_report_voter.filter([r.id, voterKey])) return r.id;
  ctx.db.reportVote.insert({ id: 0n, report_id: r.id, voter_key: voterKey });
  const count = r.reporter_count + 1;
  ctx.db.communityReport.id.update({
    ...r,
    reporter_count: count,
    label_visible: count >= LABEL_THRESHOLD,
    campaign_id: r.campaign_id || campaignId,
    last_reported_at: ctx.timestamp,
  });
  return r.id;
}

// --- community floor (D14 / section 7a) -------------------------------------------------

const VERDICT_RANK: Record<string, number> = { safe: 0, suspicious: 1, likely_scam: 2 };
export function maxVerdict(a: string, b: string): string {
  return (VERDICT_RANK[a] ?? 0) >= (VERDICT_RANK[b] ?? 0) ? a : b;
}

const REFUND_RE = /\b(refund|recover(ed|y)?|reclaim|lost (money|funds)|release (fee|your)|compensation)\b/i;

/**
 * The minimum verdict the community evidence supports. The model may raise a verdict
 * above this floor but never lower it (mirrors D2 for severity).
 */
export function communityFloor(
  ctx: Ctx,
  p: PersonRow | null,
  senderE164: string,
  linkDomains: string[],
  text: string,
  similarityFloor: string
): { floor: string; campaignId: bigint } {
  let floor = VERDICT_RANK[similarityFloor] !== undefined ? similarityFloor : 'safe';
  let campaignId = 0n;
  const exact = [
    senderE164 ? findReport(ctx, 'number', normalizeValue('number', senderE164)) : null,
    ...linkDomains.map(d => findReport(ctx, 'link', normalizeValue('link', d))),
  ];
  for (const r of exact) {
    if (!r) continue;
    floor = maxVerdict(floor, r.reporter_count >= LABEL_THRESHOLD ? 'likely_scam' : 'suspicious');
    campaignId ||= r.campaign_id;
  }
  if (p) {
    if (p.recovery_watch_until.microsSinceUnixEpoch > now(ctx) && REFUND_RE.test(text)) floor = 'likely_scam';
    if (p.campaign_watch_until.microsSinceUnixEpoch > now(ctx)) {
      if (senderE164 && senderE164 === p.watch_caller_e164) floor = maxVerdict(floor, 'likely_scam');
    }
  }
  return { floor, campaignId };
}
