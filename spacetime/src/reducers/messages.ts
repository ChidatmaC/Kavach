// Inbound messages, scam checks and the community corpus (D14/D15, section 7a).
import { SenderError, t } from 'spacetimedb/server';
import spacetimedb from '../tables';
import { burnSharedSignInCodes } from '../signin';
import {
  communityFloor, e164, maxVerdict, normalizeValue, oneOf, redact, requirePersonAccess,
  requireService, senderPerson, serviceRole, voteReport,
} from '../lib';

const CHECK_SOURCES = ['imessage', 'share', 'app_paste', 'screenshot', 'call'] as const;
const VERDICTS = ['safe', 'suspicious', 'likely_scam'] as const;

/** Photon: idempotent on photon_message_id. */
export const record_inbound_message = spacetimedb.reducer(
  { photon_message_id: t.string(), from_e164: t.string(), channel: t.string(), body: t.string() },
  (ctx, a) => {
    requireService(ctx, 'photon');
    if (!a.photon_message_id) throw new SenderError('photon_message_id required');
    if (ctx.db.inboundMessage.photon_message_id.find(a.photon_message_id)) return;
    const p = ctx.db.person.phone_e164.find(a.from_e164);
    ctx.db.inboundMessage.insert({
      id: 0n, from_e164: a.from_e164, person_id: p?.id ?? 0n, channel: a.channel.slice(0, 16),
      body: a.body.slice(0, 4000), photon_message_id: a.photon_message_id, received_at: ctx.timestamp,
    });
    // Someone texted their own pending sign-in code (codes are only entered in the app): cancel it.
    burnSharedSignInCodes(ctx, a.from_e164, a.body);
  }
);

/**
 * Agents: store a verdict. The stored verdict is max(model verdict, community floor):
 * exact number/link matches are recomputed here from community_report, and the agent
 * passes the similarity floor it found. Suspicious and likely_scam checks feed the
 * corpus and count the sender and link domains as community reports.
 */
export const save_message_check = spacetimedb.reducer(
  {
    request_key: t.string(),
    person_id: t.u64(),
    source: t.string(),
    content: t.string(), // redacted again here, defensively
    model_verdict: t.string(),
    reason: t.string(),
    campaign_id: t.u64(),
    sender_e164: t.string(),
    link_domains: t.array(t.string()),
    similarity_floor: t.string(), // "" | suspicious | likely_scam
    tactics: t.array(t.string()),
    evidence_count: t.u32(),
  },
  (ctx, a) => {
    requireService(ctx, 'agents');
    if (!a.request_key) throw new SenderError('request_key required');
    if (ctx.db.messageCheck.request_key.find(a.request_key)) return;
    const p = requirePersonAccess(ctx, a.person_id);
    oneOf('source', a.source, CHECK_SOURCES);
    oneOf('model_verdict', a.model_verdict, VERDICTS);
    e164('sender_e164', a.sender_e164, true);
    const content = redact(a.content).slice(0, 1000);
    const domains = a.link_domains.map(d => normalizeValue('link', d)).filter(Boolean).slice(0, 5);
    const { floor, campaignId } = communityFloor(ctx, p, a.sender_e164, domains, content, a.similarity_floor);
    const verdict = maxVerdict(a.model_verdict, floor);
    const campaign = a.campaign_id || campaignId;
    ctx.db.messageCheck.insert({
      id: 0n, request_key: a.request_key, person_id: p.id, source: a.source, content_redacted: content,
      verdict, model_verdict: a.model_verdict, reason: a.reason.slice(0, 300), campaign_id: campaign,
      evidence_count: a.evidence_count, created_at: ctx.timestamp,
    });
    if (verdict !== 'safe') {
      const voter = `p:${p.id}`;
      let reportId = 0n;
      if (a.sender_e164) reportId = voteReport(ctx, 'number', a.sender_e164, voter, campaign);
      for (const d of domains) reportId = voteReport(ctx, 'link', d, voter, campaign) || reportId;
      ctx.db.reportEvidence.insert({
        id: 0n, report_id: reportId, incident_id: 0n, source: 'message', channel: a.source, sender_e164: a.sender_e164,
        links: domains, claimed_identity: '', tactics: a.tactics.slice(0, 8), text_redacted: content,
        verdict, campaign_id: campaign, created_at: ctx.timestamp,
      });
    }
  }
);

/** Agents: add a redacted evidence row (e.g. a described call script). */
export const add_report_evidence = spacetimedb.reducer(
  {
    source: t.string(),
    channel: t.string(),
    sender_e164: t.string(),
    links: t.array(t.string()),
    claimed_identity: t.string(),
    tactics: t.array(t.string()),
    text: t.string(),
    verdict: t.string(),
    campaign_id: t.u64(),
  },
  (ctx, a) => {
    requireService(ctx, 'agents');
    oneOf('source', a.source, ['message', 'call', 'hotline', 'seed']);
    oneOf('verdict', a.verdict, ['suspicious', 'likely_scam']);
    e164('sender_e164', a.sender_e164, true);
    ctx.db.reportEvidence.insert({
      id: 0n, report_id: 0n, incident_id: 0n, source: a.source, channel: a.channel.slice(0, 16), sender_e164: a.sender_e164,
      links: a.links.map(l => normalizeValue('link', l)).filter(Boolean).slice(0, 5),
      claimed_identity: redact(a.claimed_identity).slice(0, 80), tactics: a.tactics.slice(0, 8),
      text_redacted: redact(a.text).slice(0, 1000), verdict: a.verdict, campaign_id: a.campaign_id,
      created_at: ctx.timestamp,
    });
  }
);

/**
 * iOS app ("Report and block") and agents. One vote per person per value; the label
 * becomes visible at LABEL_THRESHOLD independent reporters.
 * Services pass the person_id they act for; the app's person_id must be its own.
 */
export const report_number = spacetimedb.reducer(
  { person_id: t.u64(), kind: t.string(), value: t.string() },
  (ctx, { person_id, kind, value }) => {
    oneOf('kind', kind, ['number', 'link', 'phrase']);
    if (kind === 'number') e164('value', value);
    if (!serviceRole(ctx)) {
      const me = senderPerson(ctx);
      if (!me || me.id !== person_id) throw new SenderError('not your person');
    } else {
      requirePersonAccess(ctx, person_id);
    }
    voteReport(ctx, kind, value, `p:${person_id}`);
  }
);
