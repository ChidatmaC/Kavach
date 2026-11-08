// Access rules (spec 5 and D15), implemented as per-sender views over private tables.
//  - my_*        : the app identity's own rows
//  - caller_labels: public, number + count only, where label_visible
//  - svc_*       : full rows, only for identities in service_account
import { t, type InferSchema, type ViewCtx as SdkViewCtx } from 'spacetimedb/server';
import spacetimedb, {
  agentTask, alertRequest, briefing, campaign, communityReport, contact, inboundMessage, incident, messageCheck, outbox,
  person, recoveryStep, reportEvidence, verification,
} from './tables';

import { SIGN_IN } from './signin';

type ViewCtx = SdkViewCtx<InferSchema<typeof spacetimedb>>;

function me(ctx: ViewCtx) {
  for (const p of ctx.db.person.owner_hex.filter(ctx.sender.toHexString())) return p;
  return null;
}
function isService(ctx: ViewCtx): boolean {
  return !!ctx.db.serviceAccount.identity.find(ctx.sender);
}
function myIncidentIds(ctx: ViewCtx, personId: bigint): bigint[] {
  return [...ctx.db.incident.person_id.filter(personId)].map(i => i.id);
}

// --- per-user ---------------------------------------------------------------

export const my_person = spacetimedb.view({ name: 'my_person', public: true }, t.array(person.rowType), ctx => {
  const p = me(ctx);
  return p ? [p] : [];
});

export const my_contacts = spacetimedb.view({ name: 'my_contacts', public: true }, t.array(contact.rowType), ctx => {
  const p = me(ctx);
  return p ? [...ctx.db.contact.person_id.filter(p.id)] : [];
});

export const my_incidents = spacetimedb.view({ name: 'my_incidents', public: true }, t.array(incident.rowType), ctx => {
  const p = me(ctx);
  return p ? [...ctx.db.incident.person_id.filter(p.id)] : [];
});

export const my_recovery_steps = spacetimedb.view({ name: 'my_recovery_steps', public: true }, t.array(recoveryStep.rowType), ctx => {
  const p = me(ctx);
  if (!p) return [];
  return myIncidentIds(ctx, p.id).flatMap(id => [...ctx.db.recoveryStep.incident_id.filter(id)]);
});

export const my_checks = spacetimedb.view({ name: 'my_checks', public: true }, t.array(messageCheck.rowType), ctx => {
  const p = me(ctx);
  return p ? [...ctx.db.messageCheck.person_id.filter(p.id)] : [];
});

export const my_briefings = spacetimedb.view({ name: 'my_briefings', public: true }, t.array(briefing.rowType), ctx => {
  const p = me(ctx);
  return p ? [...ctx.db.briefing.person_id.filter(p.id)] : [];
});


/** Trusted Sender Check: pending verifications this app user (the relative) must answer. */
export const my_pending_verifications = spacetimedb.view(
  { name: 'my_pending_verifications', public: true }, t.array(verification.rowType), ctx => {
    const p = me(ctx);
    if (!p) return [];
    const myContactRows = [...ctx.db.contact.phone_e164.filter(p.phone_e164)].map(c => c.id);
    return [...ctx.db.verification.iter()].filter(v => v.status === 'pending' && myContactRows.includes(v.contact_id));
  }
);

/** Family replies to this person's help requests, alerts and verifications (pending / acknowledged / unanswered). */
export const my_alert_requests = spacetimedb.view({ name: 'my_alert_requests', public: true }, t.array(alertRequest.rowType), ctx => {
  const p = me(ctx);
  return p ? [...ctx.db.alertRequest.person_id.filter(p.id)] : [];
});

/**
 * The caller's pending phone sign-in, if any. Deliberately omits code_hash and salt: no view, not even
 * a svc_* one, exposes the code or anything derived from it.
 */
const SignInStatus = t.row('SignInStatusRow', {
  phone_e164: t.string(),
  attempts_left: t.u8(),
  last_error: t.string(), // "" | wrong_code | too_many_attempts
  expires_at: t.timestamp(),
  created_at: t.timestamp(),
});
export const my_sign_in = spacetimedb.view({ name: 'my_sign_in', public: true }, t.array(SignInStatus), ctx =>
  [...ctx.db.signInChallenge.requester_hex.filter(ctx.sender.toHexString())].map(c => ({
    phone_e164: c.phone_e164,
    attempts_left: Math.max(0, SIGN_IN.maxAttempts - c.attempts),
    last_error: c.last_error,
    expires_at: c.expires_at,
    created_at: c.created_at,
  })));

// --- public -------------------------------------------------------------------

const CallerLabel = t.row('CallerLabelRow', { value: t.string(), reporter_count: t.u32() });

/** Call Directory feed: numbers only, with a count, once 3+ people reported them. */
export const caller_labels = spacetimedb.anonymousView({ name: 'caller_labels', public: true }, t.array(CallerLabel), ctx =>
  [...ctx.db.communityReport.iter()]
    .filter(r => r.kind === 'number' && r.label_visible)
    .map(r => ({ value: r.value, reporter_count: r.reporter_count }))
);

// --- services -------------------------------------------------------------------

export const svc_person = spacetimedb.view({ name: 'svc_person', public: true }, t.array(person.rowType),
  ctx => (isService(ctx) ? [...ctx.db.person.iter()] : []));
export const svc_contact = spacetimedb.view({ name: 'svc_contact', public: true }, t.array(contact.rowType),
  ctx => (isService(ctx) ? [...ctx.db.contact.iter()] : []));
export const svc_incident = spacetimedb.view({ name: 'svc_incident', public: true }, t.array(incident.rowType),
  ctx => (isService(ctx) ? [...ctx.db.incident.iter()] : []));
export const svc_recovery_step = spacetimedb.view({ name: 'svc_recovery_step', public: true }, t.array(recoveryStep.rowType),
  ctx => (isService(ctx) ? [...ctx.db.recoveryStep.iter()] : []));
export const svc_message_check = spacetimedb.view({ name: 'svc_message_check', public: true }, t.array(messageCheck.rowType),
  ctx => (isService(ctx) ? [...ctx.db.messageCheck.iter()] : []));
export const svc_community_report = spacetimedb.view({ name: 'svc_community_report', public: true }, t.array(communityReport.rowType),
  ctx => (isService(ctx) ? [...ctx.db.communityReport.iter()] : []));
export const svc_report_evidence = spacetimedb.view({ name: 'svc_report_evidence', public: true }, t.array(reportEvidence.rowType),
  ctx => (isService(ctx) ? [...ctx.db.reportEvidence.iter()] : []));
export const svc_outbox = spacetimedb.view({ name: 'svc_outbox', public: true }, t.array(outbox.rowType),
  ctx => (isService(ctx) ? [...ctx.db.outbox.iter()] : []));
export const svc_inbound_message = spacetimedb.view({ name: 'svc_inbound_message', public: true }, t.array(inboundMessage.rowType),
  ctx => (isService(ctx) ? [...ctx.db.inboundMessage.iter()] : []));
export const svc_verification = spacetimedb.view({ name: 'svc_verification', public: true }, t.array(verification.rowType),
  ctx => (isService(ctx) ? [...ctx.db.verification.iter()] : []));
export const svc_briefing = spacetimedb.view({ name: 'svc_briefing', public: true }, t.array(briefing.rowType),
  ctx => (isService(ctx) ? [...ctx.db.briefing.iter()] : []));
export const svc_opt_out = spacetimedb.view(
  { name: 'svc_opt_out', public: true }, t.array(t.row('OptOutRow', { phone_e164: t.string() })),
  ctx => (isService(ctx) ? [...ctx.db.optOut.iter()].map(o => ({ phone_e164: o.phone_e164 })) : []));

export const svc_agent_task = spacetimedb.view({ name: 'svc_agent_task', public: true }, t.array(agentTask.rowType),
  ctx => (isService(ctx) ? [...ctx.db.agentTask.iter()] : []));

export const svc_alert_request = spacetimedb.view({ name: 'svc_alert_request', public: true }, t.array(alertRequest.rowType),
  ctx => (isService(ctx) ? [...ctx.db.alertRequest.iter()] : []));

// campaign is a public table; no view needed.
void campaign;
