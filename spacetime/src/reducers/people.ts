// Identity, people, settings and family contacts.
import { SenderError, t } from 'spacetimedb/server';
import { Timestamp } from 'spacetimedb';
import spacetimedb from '../tables';
import {
  ZERO_TS, appName, e164, oneOf, queueMessage, requirePersonAccess, requireService, senderPerson, serviceRole,
} from '../lib';

const ROLES = ['agents', 'photon', 'voice', 'admin'] as const;
const CHANNELS = ['imessage', 'sms', 'rcs', 'whatsapp'] as const;

/** A service presents the shared claim key once to bind its identity to a role (spec 12). */
export const claim_service = spacetimedb.reducer(
  { role: t.string(), key: t.string() },
  (ctx, { role, key }) => {
    oneOf('role', role, ROLES);
    if (!ctx.env.SERVICE_CLAIM_KEY || key !== ctx.env.SERVICE_CLAIM_KEY) throw new SenderError('bad claim key');
    const existing = ctx.db.serviceAccount.identity.find(ctx.sender);
    if (existing) ctx.db.serviceAccount.identity.update({ ...existing, role });
    else ctx.db.serviceAccount.insert({ identity: ctx.sender, role });
  }
);

function newPerson(phone: string, name: string, ownerHex: string, now: Timestamp) {
  return {
    id: 0n, owner_hex: ownerHex, phone_e164: phone, display_name: name,
    accessibility_mode: false, sharing_paused: false, critical_overrides_pause: false, practice_consent: false,
    apns_token: '', family_code_word: '', tz_offset_minutes: -360,
    recovery_watch_until: ZERO_TS, campaign_watch_until: ZERO_TS, watch_campaign_id: 0n, watch_caller_e164: '',
    created_at: now,
  };
}

/** iOS app: create or claim the person for this phone and bind it to the caller's identity. */
export const register_person = spacetimedb.reducer(
  { phone: t.string(), name: t.string() },
  (ctx, { phone, name }) => {
    e164('phone', phone);
    const n = name.trim().slice(0, 60);
    if (!n) throw new SenderError('name required');
    const mine = senderPerson(ctx);
    if (mine && mine.phone_e164 !== phone) throw new SenderError('this device is registered to another number');
    const existing = ctx.db.person.phone_e164.find(phone);
    const hex = ctx.sender.toHexString();
    if (existing) {
      // MVP: phone ownership is not verified by SMS code yet (see docs/CONTRACTS.md).
      if (existing.owner_hex && existing.owner_hex !== hex) throw new SenderError('number already registered');
      ctx.db.person.id.update({ ...existing, owner_hex: hex, display_name: n });
    } else {
      ctx.db.person.insert(newPerson(phone, n, hex, ctx.timestamp));
    }
    // Link any contact rows that point at this number.
    const p = ctx.db.person.phone_e164.find(phone)!;
    for (const c of ctx.db.contact.phone_e164.filter(phone)) {
      ctx.db.contact.id.update({ ...c, is_app_user: true, linked_person_id: p.id });
    }
  }
);

/** Services: make sure a person row exists for a texter or caller. */
export const ensure_person = spacetimedb.reducer(
  { phone: t.string(), name: t.string() },
  (ctx, { phone, name }) => {
    requireService(ctx, 'photon', 'voice', 'agents');
    e164('phone', phone);
    if (!ctx.db.person.phone_e164.find(phone)) ctx.db.person.insert(newPerson(phone, name.trim().slice(0, 60) || 'Friend', '', ctx.timestamp));
  }
);

export const update_settings = spacetimedb.reducer(
  {
    person_id: t.u64(),
    accessibility_mode: t.bool(),
    sharing_paused: t.bool(),
    critical_overrides_pause: t.bool(),
    practice_consent: t.bool(),
    apns_token: t.string(),
    family_code_word: t.string(),
    tz_offset_minutes: t.i32(),
  },
  (ctx, a) => {
    const p = requirePersonAccess(ctx, a.person_id);
    if (a.tz_offset_minutes < -720 || a.tz_offset_minutes > 840) throw new SenderError('bad tz offset');
    ctx.db.person.id.update({
      ...p,
      accessibility_mode: a.accessibility_mode,
      sharing_paused: a.sharing_paused,
      critical_overrides_pause: a.critical_overrides_pause,
      practice_consent: a.practice_consent,
      apns_token: a.apns_token.slice(0, 200),
      family_code_word: a.family_code_word.trim().slice(0, 60),
      tz_offset_minutes: a.tz_offset_minutes,
    });
  }
);

/** Text commands "pause" / "resume" (photon) and the Family screen toggle. */
export const set_sharing_paused = spacetimedb.reducer(
  { person_id: t.u64(), paused: t.bool() },
  (ctx, { person_id, paused }) => {
    const p = requirePersonAccess(ctx, person_id);
    ctx.db.person.id.update({ ...p, sharing_paused: paused });
  }
);

export const upsert_contact = spacetimedb.reducer(
  {
    person_id: t.u64(),
    contact_id: t.u64(), // 0 = new
    name: t.string(),
    phone_e164: t.string(),
    relationship: t.string(),
    channel: t.string(),
    is_emergency_contact: t.bool(),
  },
  (ctx, a) => {
    const p = requirePersonAccess(ctx, a.person_id);
    e164('phone_e164', a.phone_e164);
    oneOf('channel', a.channel, CHANNELS);
    const name = a.name.trim().slice(0, 60);
    if (!name) throw new SenderError('name required');
    const linked = ctx.db.person.phone_e164.find(a.phone_e164);
    if (a.is_emergency_contact) {
      for (const c of ctx.db.contact.person_id.filter(p.id)) {
        if (c.is_emergency_contact && c.id !== a.contact_id) ctx.db.contact.id.update({ ...c, is_emergency_contact: false });
      }
    }
    const fields = {
      name, phone_e164: a.phone_e164, relationship: a.relationship.slice(0, 40), channel: a.channel,
      is_emergency_contact: a.is_emergency_contact, is_app_user: !!linked?.owner_hex, linked_person_id: linked?.id ?? 0n,
    };
    if (a.contact_id === 0n) {
      ctx.db.contact.insert({ id: 0n, person_id: p.id, consent_status: 'invited', ...fields });
      queueMessage(ctx, {
        to_e164: a.phone_e164, channel: a.channel, kind: 'system', priority: 'normal',
        body: `${p.display_name} added you as a family contact in ${appName(ctx)}, so you'd hear if a scammer gets to them. Reply "join ${p.display_name}" to accept, or "stop" to opt out.`,
      });
    } else {
      const c = ctx.db.contact.id.find(a.contact_id);
      if (!c || c.person_id !== p.id) throw new SenderError('unknown contact');
      ctx.db.contact.id.update({ ...c, ...fields });
    }
  }
);

export const remove_contact = spacetimedb.reducer(
  { contact_id: t.u64() },
  (ctx, { contact_id }) => {
    const c = ctx.db.contact.id.find(contact_id);
    if (!c) throw new SenderError('unknown contact');
    requirePersonAccess(ctx, c.person_id);
    ctx.db.contact.id.delete(contact_id);
  }
);

/** Photon: contact replied "join <name>" / declined. */
export const set_contact_consent = spacetimedb.reducer(
  { contact_id: t.u64(), consent_status: t.string() },
  (ctx, { contact_id, consent_status }) => {
    requireService(ctx, 'photon', 'agents');
    oneOf('consent_status', consent_status, ['invited', 'accepted', 'declined']);
    const c = ctx.db.contact.id.find(contact_id);
    if (!c) throw new SenderError('unknown contact');
    ctx.db.contact.id.update({ ...c, consent_status });
  }
);

/** "stop" from anyone, on any channel (spec 9, 12). */
export const opt_out_number = spacetimedb.reducer(
  { phone: t.string(), opt_out: t.bool() },
  (ctx, { phone, opt_out }) => {
    if (!serviceRole(ctx)) {
      const p = senderPerson(ctx);
      if (!p || p.phone_e164 !== phone) throw new SenderError('not your number');
    }
    if (opt_out) {
      if (!ctx.db.optOut.phone_e164.find(phone)) ctx.db.optOut.insert({ phone_e164: phone, created_at: ctx.timestamp });
      for (const c of ctx.db.contact.phone_e164.filter(phone)) ctx.db.contact.id.update({ ...c, consent_status: 'declined' });
    } else {
      ctx.db.optOut.phone_e164.delete(phone);
    }
  }
);
