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
