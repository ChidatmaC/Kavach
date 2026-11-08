// End-to-end against a real local SpacetimeDB database (default "kavach-photon", never the shared
// "kavach"), with a stub agent service and a fake gateway. Tests run in order and share state.
//
// Prereq (repo root): spacetime publish kavach-photon ... ; npx tsx scripts/service_tokens.ts
// beforeAll runs scripts/demo_reset.ts against that database.
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AgentClient } from '../../src/agent';
import { REPO_ROOT, loadEnv, tokenFor } from '../../src/config';
import type { InboundEvent } from '../../src/gateway/types';
import { InboundProcessor } from '../../src/inbound';
import { OutboxProcessor } from '../../src/outbox';
import { Stdb, type OutboxRow } from '../../src/stdb';
import { FakeGateway } from '../helpers';

loadEnv();
const DB = process.env.INTEGRATION_DB || 'kavach-photon';
const URI = process.env.SPACETIME_URI || 'http://127.0.0.1:3000';
const JOE = '+15555550101';
const TOMMY = '+15555550102';
const MARIA = '+15555550103';
const PRIYA = '+15555550104';

interface StubCall { path: string; body: Record<string, unknown> }
const calls: StubCall[] = [];
let routerReply: (body: Record<string, unknown>) => unknown = () => ({ intent: 'scam_check', args: {} });
let commandStatus = 200;
let stub: Server;

function startStub(port: number): Promise<Server> {
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', c => (raw += c));
    req.on('end', () => {
      const body = raw ? JSON.parse(raw) : {};
      calls.push({ path: req.url ?? '', body });
      const send = (status: number, json: unknown) => {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(JSON.stringify(json));
      };
      if (req.headers.authorization !== 'Bearer test-agent-token') return send(401, { error: 'unauthorized' });
      switch (req.url) {
        case '/run/router': return send(200, routerReply(body));
        case '/run/scam_check': return send(200, { verdict: 'likely_scam', reason: 'stub', campaign_id: 0, tips: [], evidence_count: 0 });
        case '/run/advise': return send(200, { verdict: 'likely_scam', answer: 'stub', next_steps: [], evidence_count: 0, already_shared: false });
        case '/run/command': return send(commandStatus, commandStatus === 200 ? { ok: true } : { error: 'boom' });
        case '/run/verify_relative': return send(200, { verification_id: 0, messages: [] });
        case '/run/interview': return send(200, { say: 'Thanks.', next_question: 'Did they ask for money?', done: false });
        case '/push': return send(200, { sent: true });
        default: return send(404, { error: 'not found' });
      }
    });
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

let photonDb: Stdb;
let agentsDb: Stdb;
let gateway: FakeGateway;
let inbound: InboundProcessor;
let outbox: OutboxProcessor;
let agent: AgentClient;

function ev(from: string, text: string, p: Partial<InboundEvent> = {}): InboundEvent {
  return { id: `test-${randomUUID()}`, from, channel: 'imessage', text, images: [], isGroup: false, receivedAt: new Date(), ...p };
}

async function drain(maxTicks = 10): Promise<void> {
  for (let i = 0; i < maxTicks; i++) {
    await outbox.tick();
    if ((await photonDb.queuedOutbox()).length === 0) return;
  }
}

const allOutbox = () => photonDb.sql<OutboxRow>('SELECT * FROM svc_outbox');
const sentTo = (n: string) => gateway.sent.filter(s => s.to.includes(n));

beforeAll(async () => {
  if (DB === 'kavach') throw new Error('integration tests must not run against the shared "kavach" database');
  const reset = spawnSync('npx', ['tsx', 'scripts/demo_reset.ts'], {
    cwd: REPO_ROOT, env: { ...process.env, SPACETIME_DB_NAME: DB }, encoding: 'utf8',
  });
  if (reset.status !== 0) throw new Error(`demo_reset failed: ${reset.stderr || reset.stdout}`);

  try {
    stub = await startStub(Number(process.env.STUB_AGENT_PORT || 8099));
  } catch {
    stub = await startStub(0); // 8099 busy: any free port
  }
  const agentUrl = `http://127.0.0.1:${(stub.address() as AddressInfo).port}`;
  photonDb = new Stdb(URI, DB, tokenFor('photon'));
  agentsDb = new Stdb(URI, DB, tokenFor('agents'));
  agent = new AgentClient(agentUrl, 'test-agent-token', 5_000);
  gateway = new FakeGateway();
  inbound = new InboundProcessor(photonDb, agent, { appName: 'Kavach', familyReplyWindowMs: 60 * 60_000 });
  outbox = new OutboxProcessor(photonDb, gateway, agent, { appName: 'Kavach' });
});

afterAll(async () => {
  await new Promise(r => stub?.close(r));
});

describe('photon-worker against kavach-photon', () => {
  let joeId = 0;
  let tommyContact = 0;
  let mariaContact = 0;

  it('seed is in place', async () => {
    const joe = await photonDb.personByPhone(JOE);
    expect(joe?.display_name).toBe('Joe');
    joeId = joe!.id;
    const contacts = await photonDb.contactsOfPerson(joeId);
    tommyContact = contacts.find(c => c.name === 'Tommy')!.id;
    mariaContact = contacts.find(c => c.name === 'Maria')!.id;
    expect(tommyContact && mariaContact).toBeTruthy();
  });

  it('"verify Tommy" from Joe runs verify_relative on the agent service (local command, no router)', async () => {
    calls.length = 0;
    const outcome = await inbound.handle(ev(JOE, 'verify Tommy'));
    expect(outcome).toBe('command:verify');
    expect(calls.map(c => c.path)).toEqual(['/run/verify_relative']);
    expect(calls[0].body).toEqual({ person_id: joeId, relative_name: 'Tommy' });
    const rec = await photonDb.sql(`SELECT * FROM svc_inbound_message WHERE from_e164 = '${JOE}'`);
    expect(rec.length).toBe(1);
  });

  it('free text from Joe reaches the router stub, then scam_check with reply_to_e164', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'scam_check', args: {} });
    const outcome = await inbound.handle(ev(JOE, 'Is this real? TxTag: unpaid toll $6.80 https://txtag-pay.top/inv/88213'));
    expect(outcome).toBe('routed:scam_check');
    expect(calls.map(c => c.path)).toEqual(['/run/router', '/run/scam_check']);
    expect(calls[0].body).toMatchObject({ from_e164: JOE, channel: 'imessage', person_id: joeId, mode: 'text' });
    expect(calls[1].body).toMatchObject({ person_id: joeId, source: 'imessage', reply_to_e164: JOE, reply_channel: 'imessage' });
  });

  it('an agent-routed text gets an instant urgent acknowledgement queued before the agent answers', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'scam_check', args: {} });
    const before = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).length;
    await inbound.handle(ev(JOE, 'Is this legit? Pay your toll at txtag-pay.top'));
    const rows = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).slice(before);
    const ack = rows.find(r => String(r.body).includes('Checking this now'));
    expect(ack).toBeTruthy();
    expect(ack!.priority).toBe('urgent');
  });

  it('a question routed as advise runs the advise workflow with reply_to_e164', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'advise', args: { person_id: joeId, text: 'my nephew wants gift cards, should I?' } });
    const outcome = await inbound.handle(ev(JOE, 'my nephew wants gift cards, should I?'));
    expect(outcome).toBe('routed:advise');
    expect(calls.map(c => c.path)).toEqual(['/run/router', '/run/advise']);
    expect(calls[1].body).toMatchObject({ person_id: joeId, text: 'my nephew wants gift cards, should I?', reply_to_e164: JOE, mode: 'text' });
  });

  it('a text routed as command runs /run/command with the router args and reply_to_e164', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'command', args: { action: 'list_family' } });
    const outcome = await inbound.handle(ev(JOE, 'who is in my family list?'));
    expect(outcome).toBe('routed:command');
    expect(calls.map(c => c.path)).toEqual(['/run/router', '/run/command']);
    expect(calls[1].body).toEqual({
      person_id: joeId, text: 'who is in my family list?', reply_to_e164: JOE, reply_channel: 'imessage',
      args: { action: 'list_family' },
    });
  });

  it('a failing /run/command queues a fallback reply', async () => {
    commandStatus = 500;
    routerReply = () => ({ intent: 'command', args: { action: 'status' } });
    const before = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).length;
    await inbound.handle(ev(JOE, 'status'));
    commandStatus = 200;
    const rows = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).slice(before);
    expect(rows.some(r => String(r.body).includes("I couldn't do that right now"))).toBe(true);
  });

  it('instant commands are not acknowledged twice', async () => {
    const before = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).length;
    await inbound.handle(ev(JOE, 'help'));
    const rows = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).slice(before);
    expect(rows.some(r => String(r.body).includes('Checking this now'))).toBe(false);
  });

  it('router out_of_scope and help produce queued replies that get delivered', async () => {
    routerReply = () => ({ intent: 'out_of_scope', args: {} });
    gateway.sent = [];
    await inbound.handle(ev(JOE, "what's the weather"));
    await inbound.handle(ev(JOE, 'help'));
    await drain();
    const bodies = sentTo(JOE).map(s => s.body);
    expect(bodies.some(b => b.includes('only helps with scams'))).toBe(true);
    expect(bodies.some(b => b.includes('verify Tommy'))).toBe(true);
  });

  it('an unknown texter gets a person row (ensure_person) before routing', async () => {
    routerReply = () => ({ intent: 'scam_check', args: {} });
    calls.length = 0;
    await inbound.handle(ev('+15555550177', 'got this text, is it a scam?'));
    const p = await photonDb.personByPhone('+15555550177');
    expect(p).not.toBeNull();
    expect(calls[0]).toMatchObject({ path: '/run/router', body: { person_id: p!.id } });
  });

  it('images go straight to scam_check as image_base64', async () => {
    calls.length = 0;
    const outcome = await inbound.handle(ev(JOE, '', { images: [{ mimeType: 'image/png', base64: 'aGVsbG8=' }] }));
    expect(outcome).toBe('image_check');
    expect(calls.map(c => c.path)).toEqual(['/run/scam_check']);
    expect(calls[0].body).toMatchObject({ image_base64: 'aGVsbG8=', reply_to_e164: JOE, source: 'screenshot' });
  });

  it('a duplicate photon_message_id is ignored (in memory and across restarts)', async () => {
    calls.length = 0;
    const e = ev(JOE, 'is this a scam? call 555-0100 now');
    expect(await inbound.handle(e)).toBe('routed:scam_check');
    expect(await inbound.handle(e)).toBe('duplicate');
    const fresh = new InboundProcessor(photonDb, agent, { appName: 'Kavach', familyReplyWindowMs: 60 * 60_000 });
    expect(await fresh.handle(e)).toBe('duplicate');
    expect(calls.filter(c => c.path === '/run/router')).toHaveLength(1);
    const rows = await photonDb.sql(`SELECT * FROM svc_inbound_message WHERE photon_message_id = '${e.id}'`);
    expect(rows).toHaveLength(1);
  });

  it('"join Joe" from an invited contact accepts the invite', async () => {
    await agentsDb.call('upsert_contact', {
      person_id: joeId, contact_id: 0, name: 'Priya', phone_e164: PRIYA, relationship: 'niece', channel: 'imessage',
      is_emergency_contact: false,
    });
    const [priya] = await photonDb.contactsByPhone(PRIYA);
    expect(priya.consent_status).toBe('invited');
    expect(await inbound.handle(ev(PRIYA, 'Join Joe'))).toBe('command:join');
    const [after] = await photonDb.contactsByPhone(PRIYA);
    expect(after.consent_status).toBe('accepted');
  });

  it('queued rows from enqueue_outbox are delivered and marked sent, urgent first; a group goes out once', async () => {
    await drain(); // flush earlier replies and the invite
    gateway.sent = [];
    const groupKey = `family:${joeId}:999`;
    await agentsDb.enqueue({ to_e164: JOE, channel: 'imessage', kind: 'reply', body: 'normal one', priority: 'normal' });
    await agentsDb.enqueue({ to_e164: JOE, channel: 'imessage', kind: 'reply', body: 'urgent one', priority: 'urgent' });
    const [priya] = await photonDb.contactsByPhone(PRIYA);
    const alert = 'Kavach: Joe asked for help during a call.';
    await agentsDb.enqueue({ to_e164: TOMMY, channel: 'imessage', kind: 'family_alert', body: alert, recipient_contact_id: tommyContact, group_key: groupKey });
    await agentsDb.enqueue({ to_e164: PRIYA, channel: 'imessage', kind: 'family_alert', body: alert, recipient_contact_id: priya.id, group_key: groupKey });
    await agentsDb.enqueue({ to_e164: JOE, channel: 'push', kind: 'system', body: 'push one', priority: 'normal' });
    calls.length = 0;
    await drain();

    expect(gateway.sent.map(s => s.body)).toEqual(['urgent one', 'normal one', alert]);
    expect(gateway.sent[2]).toMatchObject({ group: groupKey, channel: 'imessage' });
    expect(gateway.sent[2].to.sort()).toEqual([TOMMY, PRIYA]);
    expect(calls.filter(c => c.path === '/push').map(c => c.body)).toEqual([
      { to_e164: JOE, title: 'Kavach', body: 'push one', category: 'system' },
    ]);
    const rows = (await allOutbox()).filter(r => ['normal one', 'urgent one', alert, 'push one'].includes(r.body));
    expect(rows).toHaveLength(5);
    expect(rows.every(r => r.status === 'sent' && r.attempts === 1)).toBe(true);
  });

  it('a failing send is retried and ends up sent; the row records attempts', async () => {
    let failures = 1;
    gateway.failWhen = r => r.body === 'flaky' && failures-- > 0;
    const clock = { t: Date.now(), now() { return this.t; } };
    const p = new OutboxProcessor(photonDb, gateway, agent, { appName: 'Kavach', clock });
    await agentsDb.enqueue({ to_e164: JOE, channel: 'imessage', kind: 'reply', body: 'flaky' });
    await p.tick();
    let [r] = (await allOutbox()).filter(x => x.body === 'flaky');
    expect(r.status).toBe('queued');
    clock.t += 5_000;
    await p.tick();
    [r] = (await allOutbox()).filter(x => x.body === 'flaky');
    expect(r.status).toBe('sent');
    expect(r.attempts).toBe(2);
    gateway.failWhen = () => false;
  });

  it('Tommy replying "not me" resolves the pending verification as denied and the warnings go out', async () => {
    const key = randomUUID();
    await agentsDb.call('start_verification', { request_key: key, person_id: joeId, contact_id: tommyContact, kind: 'relay' });
    const [v] = await photonDb.sql<{ id: number; status: string }>(`SELECT * FROM svc_verification WHERE request_key = '${key}'`);
    expect(v.status).toBe('pending');
    gateway.sent = [];

    expect(await inbound.handle(ev(TOMMY, 'Not me!'))).toBe('command:deny');
    const [after] = await photonDb.sql<{ status: string }>(`SELECT * FROM svc_verification WHERE id = ${v.id}`);
    expect(after.status).toBe('denied');

    await drain();
    const toJoe = sentTo(JOE).find(s => s.body.includes('NOT them'));
    expect(toJoe).toBeTruthy();
    expect(sentTo(MARIA).find(s => s.body.includes("wasn't them"))?.channel).toBe('sms');
    expect(sentTo(PRIYA).some(s => s.body.includes("wasn't them"))).toBe(true);
    expect(sentTo(TOMMY).some(s => s.body.includes("We've told Joe it's a scam"))).toBe(true);
    // urgent warning to Joe went first
    expect(gateway.sent[0].to).toEqual([JOE]);
    const warnings = (await allOutbox()).filter(r => r.kind === 'verification' || r.body.includes("wasn't them"));
    expect(warnings.length).toBeGreaterThanOrEqual(3);
    expect(warnings.every(r => r.status === 'sent')).toBe(true);
  });

  it('a family member\'s free-text reply is relayed to the others, prefixed with their name', async () => {
    gateway.sent = [];
    calls.length = 0;
    expect(await inbound.handle(ev(TOMMY, "Thanks, I'll check on Grandpa tonight"))).toBe('relay');
    expect(calls).toHaveLength(0); // not routed
    await drain();
    const relayed = gateway.sent.filter(s => s.body === "Tommy: Thanks, I'll check on Grandpa tonight");
    expect(relayed.map(s => s.to[0]).sort()).toEqual([MARIA, PRIYA]);
  });

  it('"I\'m calling" from a contact records family_ack on the latest High incident', async () => {
    const incidentId = await agentsDb.openIncident(joeId, 'imessage', '+15555550199');
    for (const [q, a] of [['q_identity', 'bank fraud team'], ['q_ask', 'yes'], ['q_shared', 'personal_details']]) {
      await agentsDb.call('save_answer', { incident_id: incidentId, question_id: q, answer: a });
    }
    const [inc] = await photonDb.sql<{ severity: string }>(`SELECT * FROM svc_incident WHERE id = ${incidentId}`);
    expect(inc.severity).toBe('high');
    expect(await inbound.handle(ev(MARIA, "I'm calling", { channel: 'sms' }))).toBe('command:ack');
    const [acked] = await photonDb.sql<{ family_ack_by: number }>(`SELECT * FROM svc_incident WHERE id = ${incidentId}`);
    expect(acked.family_ack_by).toBe(mariaContact);
  });

  async function openHelpRequest(): Promise<{ incidentId: number; requestId: number }> {
    const key = randomUUID();
    await agentsDb.call('open_incident', { request_key: key, person_id: joeId, entry_point: 'companion', caller_e164: '' });
    const [inc] = await photonDb.sql<{ id: number }>(`SELECT * FROM svc_incident WHERE request_key = '${key}'`);
    const [req] = await photonDb.sql<{ id: number; kind: string; status: string }>(
      `SELECT * FROM svc_alert_request WHERE incident_id = ${inc.id}`);
    expect(req).toMatchObject({ kind: 'help', status: 'pending' });
    return { incidentId: inc.id, requestId: req.id };
  }

  it('Tommy\'s "ok" acknowledges the pending help request: no relay, no scam check, Joe is told', async () => {
    const { requestId } = await openHelpRequest();
    await drain();
    gateway.sent = [];
    calls.length = 0;
    const before = (await allOutbox()).length;

    expect(await inbound.handle(ev(TOMMY, 'ok'))).toBe('family_ack');
    expect(calls).toHaveLength(0); // not routed, not scam-checked
    const [req] = await photonDb.sql<{ status: string; acked_by_contact_id: number }>(
      `SELECT * FROM svc_alert_request WHERE id = ${requestId}`);
    expect(req.status).toBe('acknowledged');
    expect(req.acked_by_contact_id).toBe(tommyContact);
    const added = (await allOutbox()).slice(before);
    expect(added.some(r => r.kind === 'relay' || r.body.startsWith('Tommy:'))).toBe(false);
    expect(added.some(r => r.body.includes('Checking this now'))).toBe(false);

    await drain();
    expect(sentTo(JOE).map(s => s.body)).toContain('Kavach: Tommy saw your request for help and replied.');
    expect(sentTo(TOMMY).map(s => s.body)).toContain("Kavach: Thanks, we've let Joe know you saw it.");
    expect(sentTo(MARIA)).toHaveLength(0);
    expect(sentTo(PRIYA)).toHaveLength(0);
  });

  it('other short acknowledgements ("👍", "got it") are not relayed or scam-checked either', async () => {
    gateway.sent = [];
    calls.length = 0;
    expect(await inbound.handle(ev(PRIYA, '👍'))).toBe('family_ack');
    expect(await inbound.handle(ev(TOMMY, 'Got it!'))).toBe('family_ack');
    expect(calls).toHaveLength(0);
    await drain();
    expect(gateway.sent.some(s => s.body.includes('👍') || s.body.includes('Got it'))).toBe(false);
    expect(sentTo(MARIA)).toHaveLength(0);
  });

  it('a family member\'s free-text reply is relayed AND acknowledges the pending request', async () => {
    const { requestId } = await openHelpRequest();
    await drain();
    gateway.sent = [];
    calls.length = 0;
    const text = 'Driving over to see him after work';
    expect(await inbound.handle(ev(PRIYA, text))).toBe('relay');
    expect(calls).toHaveLength(0);
    const [priya] = await photonDb.contactsByPhone(PRIYA);
    const [req] = await photonDb.sql<{ status: string; acked_by_contact_id: number }>(
      `SELECT * FROM svc_alert_request WHERE id = ${requestId}`);
    expect(req).toMatchObject({ status: 'acknowledged', acked_by_contact_id: priya.id });
    await drain();
    const relayed = gateway.sent.filter(s => s.body === `Priya: ${text}`);
    expect(relayed.flatMap(s => s.to).sort()).toEqual([TOMMY, MARIA].sort());
    expect(sentTo(JOE).map(s => s.body)).toContain('Kavach: Priya saw your request for help and replied.');
  });

  // --- forwarded-message wrapper and the clarifying question (CONTRACTS section 7) -------------

  it('a wrapped forward with "verify Tommy" inside is routed (scam-checked), not run as a verify command', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'scam_check', args: { text: 'verify Tommy', sender_e164: '' } });
    const outcome = await inbound.handle(ev(JOE, 'Forwarded message:\n"verify Tommy"'));
    expect(outcome).toBe('routed:scam_check');
    expect(calls.map(c => c.path)).toEqual(['/run/router', '/run/scam_check']);
    expect(calls[0].body.text).toBe('Forwarded message:\n"verify Tommy"'); // the router strips the wrapper
    expect(calls[1].body).toMatchObject({ text: 'verify Tommy', person_id: joeId });
  });

  it('"Check this" and "Forwarded" wrappers are not swallowed by local commands', async () => {
    for (const text of ['Check this: stop', 'Forwarded: help', 'Check this "yes"']) {
      calls.length = 0;
      routerReply = () => ({ intent: 'scam_check', args: {} });
      expect(await inbound.handle(ev(JOE, text))).toBe('routed:scam_check');
      expect(calls[0].path).toBe('/run/router');
    }
    expect((await photonDb.optOuts()).has(JOE)).toBe(false);
  });

  it('a family member\'s wrapped forward is not taken as a short ack or relayed: it is routed', async () => {
    const { requestId } = await openHelpRequest();
    await drain();
    gateway.sent = [];
    calls.length = 0;
    routerReply = () => ({ intent: 'scam_check', args: { text: 'ok' } });
    const before = (await allOutbox()).length;
    expect(await inbound.handle(ev(TOMMY, 'Fwd: ok'))).toBe('routed:scam_check');
    expect(calls.map(c => c.path)).toEqual(['/run/router', '/run/scam_check']);
    const added = (await allOutbox()).slice(before);
    expect(added.some(r => r.kind === 'relay' || r.body.startsWith('Tommy:'))).toBe(false);
    const [req] = await photonDb.sql<{ status: string }>(`SELECT * FROM svc_alert_request WHERE id = ${requestId}`);
    expect(req.status).toBe('pending'); // a forward is not "I saw your alert"
    expect(await inbound.handle(ev(TOMMY, 'ok'))).toBe('family_ack'); // a plain "ok" still is
  });

  it('a bare "Fwd:" gets no acknowledgement and no reply; the router is told so it can expect the forward', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'clarify', args: { reply: '', reason: 'await_forward' } });
    const before = (await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).length;
    expect(await inbound.handle(ev(JOE, 'Fwd:'))).toBe('routed:clarify');
    expect(calls.map(c => c.path)).toEqual(['/run/router']);
    expect((await photonDb.sql(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`)).length).toBe(before);
  });

  it('an ambiguous text gets the clarifying question; a family member\'s "2" to it goes to the router, not the family relay', async () => {
    await drain();
    calls.length = 0;
    const question = 'Kavach: Is this a message you received, or a question for me? Reply 1 if you received it, 2 if it\'s your question.';
    routerReply = () => ({ intent: 'clarify', args: { reply: question, reason: 'ambiguous' } });
    expect(await inbound.handle(ev(JOE, 'send money'))).toBe('routed:clarify');
    const rows = await photonDb.sql<OutboxRow>(`SELECT * FROM svc_outbox WHERE to_e164 = '${JOE}'`);
    expect(rows.some(r => r.body === question)).toBe(true);
    // Tommy (a family contact, recently texted about Joe) also uses Kavach and was asked the same question.
    await photonDb.enqueue({ to_e164: TOMMY, channel: 'imessage', kind: 'reply', body: question, priority: 'normal' });

    calls.length = 0;
    routerReply = () => ({ intent: 'advise', args: { text: 'send money' } });
    expect(await inbound.handle(ev(TOMMY, '2'))).toBe('routed:advise');
    expect(calls.map(c => c.path)).toEqual(['/run/router', '/run/advise']);
    expect(calls[1].body).toMatchObject({ text: 'send money', reply_to_e164: TOMMY });
  });

  it('a command chosen after "2" runs on the remembered text with the router\'s parsed args', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'command', args: {
      person_id: joeId, text: 'report the last one', reply_to_e164: JOE, reply_channel: 'imessage',
      args: { action: 'report', target: 'last' } } });
    expect(await inbound.handle(ev(JOE, '2'))).toBe('routed:command');
    expect(calls[1]).toMatchObject({ path: '/run/command', body: {
      person_id: joeId, text: 'report the last one', args: { action: 'report', target: 'last' } } });
  });

  it('the scam check passes teach_wrapper through when the router asks for the tip', async () => {
    calls.length = 0;
    routerReply = () => ({ intent: 'scam_check', args: { text: 'USPS: your package is on hold', teach_wrapper: true } });
    await inbound.handle(ev(JOE, 'USPS: your package is on hold'));
    expect(calls[1].body).toMatchObject({ text: 'USPS: your package is on hold', teach_wrapper: true });
  });

  it('"stop" adds an opt-out, confirms once, and later messages are suppressed', async () => {
    await drain();
    gateway.sent = [];
    expect(await inbound.handle(ev(MARIA, 'STOP', { channel: 'sms' }))).toBe('command:stop');
    const optOuts = await photonDb.optOuts();
    expect(optOuts.has(MARIA)).toBe(true);
    const [maria] = await photonDb.contactsByPhone(MARIA);
    expect(maria.consent_status).toBe('declined');

    await agentsDb.enqueue({ to_e164: MARIA, channel: 'sms', kind: 'reply', body: 'should not arrive' });
    await drain();
    expect(sentTo(MARIA).map(s => s.body)).toEqual([
      "Kavach: You're unsubscribed and won't get more messages from us. Text START to turn them back on.",
    ]);
    expect((await allOutbox()).some(r => r.body === 'should not arrive')).toBe(false);

    // Further texts from an opted-out number are ignored until START.
    calls.length = 0;
    expect(await inbound.handle(ev(MARIA, 'is this a scam?', { channel: 'sms' }))).toBe('ignored_opted_out');
    expect(calls).toHaveLength(0);
  });
});
