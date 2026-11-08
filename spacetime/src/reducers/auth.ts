// Phone sign-in (see docs/CONTRACTS.md section 7, "Sign-in by one-time code").
//
// The session credential stays a SpacetimeDB identity + token (POST /v1/identity). What these
// reducers add is proof that the identity controls the phone number: a 6-digit code texted to it.
// Verifying binds person.owner_hex to the caller and releases any other binding, so the newest
// device wins and the previous token stops seeing my_* rows.
import { SenderError, t } from 'spacetimedb/server';
import { Timestamp } from 'spacetimedb';
import spacetimedb from '../tables';
import { type Ctx, ZERO_TS, appName, e164, queueMessage, serviceRole } from '../lib';
import {
  DEMO_CODE, SIGN_IN, hashCode, isDemoNumber, newCode, sameHash, signInMessage,
} from '../signin';

type ChallengeRow = NonNullable<ReturnType<Ctx['db']['signInChallenge']['id']['find']>>;

function nowMicros(ctx: Ctx): bigint {
  return ctx.timestamp.microsSinceUnixEpoch;
}

function requireAppIdentity(ctx: Ctx) {
  if (serviceRole(ctx)) throw new SenderError('service identities cannot sign in');
}

function minutesLeft(ctx: Ctx, until: Timestamp): number {
  return Math.max(1, Math.ceil(Number(until.microsSinceUnixEpoch - nowMicros(ctx)) / 60_000_000));
}

function myChallenge(ctx: Ctx, phone: string): ChallengeRow | null {
  const hex = ctx.sender.toHexString();
  for (const c of ctx.db.signInChallenge.requester_hex.filter(hex)) if (c.phone_e164 === phone) return c;
  return null;
}

/** Drops request-log rows older than the rate window for this phone and identity, then counts. */
function recentRequests(ctx: Ctx, phone: string, hex: string): { byPhone: number; byIdentity: number } {
  const cutoff = nowMicros(ctx) - SIGN_IN.rateWindow;
  const rows = new Map<bigint, { created_at: Timestamp }>();
  for (const r of ctx.db.signInRequestLog.phone_e164.filter(phone)) rows.set(r.id, r);
  for (const r of ctx.db.signInRequestLog.requester_hex.filter(hex)) rows.set(r.id, r);
  for (const [id, r] of rows) if (r.created_at.microsSinceUnixEpoch < cutoff) ctx.db.signInRequestLog.id.delete(id);
  let byPhone = 0;
  let byIdentity = 0;
  for (const r of ctx.db.signInRequestLog.phone_e164.filter(phone)) if (r.created_at.microsSinceUnixEpoch >= cutoff) byPhone++;
  for (const r of ctx.db.signInRequestLog.requester_hex.filter(hex)) if (r.created_at.microsSinceUnixEpoch >= cutoff) byIdentity++;
  return { byPhone, byIdentity };
}

/**
 * App: text a 6-digit sign-in code to `phone`. Replaces this identity's previous pending code.
 * Limits: 5 requests per phone and per identity per hour, 30 s between resends, and a locked
 * challenge (5 wrong codes) blocks new codes for that phone until it expires.
 */
export const request_sign_in = spacetimedb.reducer(
  { phone: t.string(), name: t.string() },
  (ctx, { phone, name }) => {
    requireAppIdentity(ctx);
    e164('phone', phone);
    const n = name.trim().slice(0, 60);
    if (!n && !ctx.db.person.phone_e164.find(phone)) throw new SenderError('name required');
    const hex = ctx.sender.toHexString();

    const prev = myChallenge(ctx, phone);
    if (prev && prev.expires_at.microsSinceUnixEpoch > nowMicros(ctx)) {
      if (prev.attempts >= SIGN_IN.maxAttempts) {
        throw new SenderError(`too many attempts: try again in ${minutesLeft(ctx, prev.expires_at)} min`);
      }
      if (prev.created_at.microsSinceUnixEpoch + SIGN_IN.resendCooldown > nowMicros(ctx)) {
        throw new SenderError('please wait 30 seconds before asking for another code');
      }
    }
    const { byPhone, byIdentity } = recentRequests(ctx, phone, hex);
    if (byPhone >= SIGN_IN.maxRequests || byIdentity >= SIGN_IN.maxRequests) {
      throw new SenderError('too many codes requested: try again in an hour');
    }

    // One pending sign-in per identity.
    for (const c of [...ctx.db.signInChallenge.requester_hex.filter(hex)]) ctx.db.signInChallenge.id.delete(c.id);

    const { code, salt } = newCode(ctx, phone);
    ctx.db.signInChallenge.insert({
      id: 0n, phone_e164: phone, requester_hex: hex, display_name: n, code_hash: hashCode(ctx, salt, code), salt,
      attempts: 0, last_error: '', expires_at: new Timestamp(nowMicros(ctx) + SIGN_IN.codeTtl), created_at: ctx.timestamp,
    });
    ctx.db.signInRequestLog.insert({ id: 0n, phone_e164: phone, requester_hex: hex, created_at: ctx.timestamp });

    // Seeded demo numbers can't receive texts; they sign in with 000000 (DEMO_MODE only).
    if (isDemoNumber(ctx, phone)) return;
    queueMessage(ctx, {
      to_e164: phone, channel: 'imessage', kind: 'system', priority: 'urgent', body: signInMessage(appName(ctx), code),
    });
  }
);

/** Binds `phone` to the caller: releases the caller's other binding and any other device's. */
function bindPhoneToSender(ctx: Ctx, phone: string, name: string) {
  const hex = ctx.sender.toHexString();
  for (const other of [...ctx.db.person.owner_hex.filter(hex)]) {
    if (other.phone_e164 !== phone) ctx.db.person.id.update({ ...other, owner_hex: '', apns_token: '' });
  }
  const existing = ctx.db.person.phone_e164.find(phone);
  if (existing) {
    ctx.db.person.id.update({
      ...existing,
      owner_hex: hex,
      display_name: name || existing.display_name,
      // A new device registers its own push token.
      apns_token: existing.owner_hex === hex ? existing.apns_token : '',
      last_sign_in_at: ctx.timestamp,
    });
  } else {
    ctx.db.person.insert({
      id: 0n, owner_hex: hex, phone_e164: phone, display_name: name || 'Friend',
      accessibility_mode: false, sharing_paused: false, critical_overrides_pause: false,
      apns_token: '', family_code_word: '', tz_offset_minutes: -360,
      recovery_watch_until: ZERO_TS, campaign_watch_until: ZERO_TS, watch_campaign_id: 0n, watch_caller_e164: '',
      created_at: ctx.timestamp, last_sign_in_at: ctx.timestamp,
    });
  }
  const p = ctx.db.person.phone_e164.find(phone)!;
  for (const c of [...ctx.db.contact.phone_e164.filter(phone)]) {
    ctx.db.contact.id.update({ ...c, is_app_user: true, linked_person_id: p.id });
  }
}

/**
 * App: enter the code. Correct → the person (created if new) is bound to the caller's identity.
 * Wrong → the call still succeeds (so the attempt counter is committed) and `my_sign_in` shows
 * `last_error = wrong_code` with `attempts_left`; after 5 wrong codes it is `too_many_attempts`
 * and the number is locked for this identity until the code expires.
 * Errors (non-2xx): bad input, no pending code, expired, locked.
 */
export const verify_sign_in = spacetimedb.reducer(
  { phone: t.string(), code: t.string() },
  (ctx, { phone, code }) => {
    requireAppIdentity(ctx);
    e164('phone', phone);
    const entered = code.replace(/\s/g, '');
    if (!/^\d{6}$/.test(entered)) throw new SenderError('enter the 6-digit code');
    const ch = myChallenge(ctx, phone);
    if (!ch) throw new SenderError('no sign-in code was requested for this number');
    if (ch.expires_at.microsSinceUnixEpoch <= nowMicros(ctx)) throw new SenderError('code expired: ask for a new code');
    if (ch.attempts >= SIGN_IN.maxAttempts) {
      throw new SenderError(`too many attempts: try again in ${minutesLeft(ctx, ch.expires_at)} min`);
    }
    const ok = (isDemoNumber(ctx, phone) && entered === DEMO_CODE) || sameHash(hashCode(ctx, ch.salt, entered), ch.code_hash);
    if (!ok) {
      const attempts = ch.attempts + 1;
      ctx.db.signInChallenge.id.update({
        ...ch, attempts, last_error: attempts >= SIGN_IN.maxAttempts ? 'too_many_attempts' : 'wrong_code',
      });
      return;
    }
    bindPhoneToSender(ctx, phone, ch.display_name);
    ctx.db.signInChallenge.id.delete(ch.id);
  }
);

/** App: release this identity's phone binding (and pending code). Idempotent. */
export const sign_out = spacetimedb.reducer(ctx => {
  const hex = ctx.sender.toHexString();
  for (const p of [...ctx.db.person.owner_hex.filter(hex)]) ctx.db.person.id.update({ ...p, owner_hex: '', apns_token: '' });
  for (const c of [...ctx.db.signInChallenge.requester_hex.filter(hex)]) ctx.db.signInChallenge.id.delete(c.id);
});
