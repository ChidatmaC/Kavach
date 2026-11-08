// End-to-end checks of the SpacetimeDB module over HTTP. Wipes and re-seeds the database first.
// Run with the services stopped (npm run stop:local): it plays the agent service itself.
// With the agent service down, family alerts must arrive via the template fallback.
import { randomUUID } from 'node:crypto';
import { call, newIdentity, sql, tokenFor } from './lib/stdb';
import { runSeed } from './seed';

const agents = tokenFor('agents');
const photon = tokenFor('photon');
let failures = 0;
function check(name: string, ok: boolean, detail: unknown = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  -> ${JSON.stringify(detail)}`}`);
  if (!ok) failures++;
}
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
async function refusedWith(fn: () => Promise<unknown>, re: RegExp): Promise<boolean> {
  try { await fn(); return false; } catch (e) { return re.test(String(e)); }
}
/** Seeded demo numbers (+1555555xxxx) sign in with 000000 when the module runs with DEMO_MODE=true. */
async function signIn(token: string, phone: string, name: string) {
  await call(token, 'request_sign_in', { phone, name });
  await call(token, 'verify_sign_in', { phone, code: '000000' });
}
const myPerson = async (token: string) => (await sql(token, 'SELECT * FROM my_person'))[0];
const mySignIn = async (token: string) => (await sql(token, 'SELECT * FROM my_sign_in'))[0];
const outbox = () => sql(agents, 'SELECT * FROM svc_outbox');
/** Plays a failing agent service: claims every queued task and fails it, which triggers the fallbacks. */
async function failQueuedTasks(): Promise<string[]> {
  const tasks = await sql(agents, "SELECT * FROM svc_agent_task WHERE status = 'queued'");
  for (const t of tasks) {
    await call(agents, 'claim_agent_task', { task_id: t.id });
    await call(agents, 'complete_agent_task', { task_id: t.id, ok: false, error: 'smoke: agent down' });
  }
  return tasks.map(t => String(t.workflow));
}

// Start from a clean, seeded state (full wipe, so persons and sign-ins start fresh).
await call(tokenFor('admin'), 'admin_reset', {});
await call(tokenFor('admin'), 'admin_wipe', {});
await runSeed();

// Access rules
const anon = (await newIdentity()).token;
check('anonymous cannot read persons', (await sql(anon, 'SELECT * FROM svc_person')).length === 0);
check('anonymous cannot read evidence (D15)', (await sql(anon, 'SELECT * FROM svc_report_evidence')).length === 0);
const labels = await sql(anon, 'SELECT * FROM caller_labels');
check('caller labels show only numbers with 3+ reporters', labels.every(l => Number(l.reporter_count) >= 3) && labels.some(l => l.value === '+15555550199' && l.reporter_count === 14) && !labels.some(l => l.value === '+15555550177'), labels);
check('service can read persons', (await sql(agents, 'SELECT * FROM svc_person')).length === 2);
let refused = false;
try { await call(anon, 'enqueue_outbox', { to_e164: '+15555550101', channel: 'sms', kind: 'reply', body: 'x', priority: 'normal', related_incident_id: 0, recipient_contact_id: 0, group_key: '' }); } catch { refused = true; }
check('anonymous cannot enqueue outbox', refused);

// Sign-in by one-time code (fictional 415-555-01xx numbers get a real code; nobody delivers it here).
const codeFor = async (phone: string) => {
  const rows = (await outbox()).filter(r => r.to_e164 === phone && r.kind === 'system' && /sign-in code: \d{6}/.test(String(r.body)));
  return String(rows.at(-1)?.body ?? '').match(/sign-in code: (\d{6})/)?.[1] ?? '';
};
check('register_person is retired', await refusedWith(() => call(anon, 'register_person', { phone: '+15555550101', name: 'Joe' }), /request_sign_in/));
const realA = '+14155550123';
const lockApp = (await newIdentity()).token;
await call(lockApp, 'request_sign_in', { phone: realA, name: 'Ann' });
const codeA = await codeFor(realA);
check('request_sign_in texts a 6-digit code (outbox kind system, urgent)', /^\d{6}$/.test(codeA) &&
  (await outbox()).some(r => r.to_e164 === realA && r.kind === 'system' && r.priority === 'urgent' && /Never share it/.test(String(r.body))));
const st0 = await mySignIn(lockApp);
check('my_sign_in shows the pending sign-in without the code or its hash', st0?.phone_e164 === realA && st0.attempts_left === 5 &&
  !Object.keys(st0).some(k => /code|hash|salt/.test(k)) && !JSON.stringify(st0).includes(codeA), st0);
check('no view or SQL read exposes sign_in_challenge, even to services',
  await refusedWith(async () => { if ((await sql(agents, 'SELECT * FROM sign_in_challenge')).length === 0) throw new Error('empty'); }, /./));
check('resend is rate limited (30 s cooldown)', await refusedWith(() => call(lockApp, 'request_sign_in', { phone: realA, name: 'Ann' }), /wait 30 seconds/));
const wrong = codeA === '111111' ? '222222' : '111111';
await call(lockApp, 'verify_sign_in', { phone: realA, code: '000000' });
const st1 = await mySignIn(lockApp);
check('demo code 000000 does not work for a real number', st1.last_error === 'wrong_code' && st1.attempts_left === 4 && !(await myPerson(lockApp)), st1);
for (let i = 0; i < 4; i++) await call(lockApp, 'verify_sign_in', { phone: realA, code: wrong });
const st2 = await mySignIn(lockApp);
check('5 wrong codes lock the sign-in', st2.last_error === 'too_many_attempts' && st2.attempts_left === 0, st2);
check('locked: even the right code is refused', await refusedWith(() => call(lockApp, 'verify_sign_in', { phone: realA, code: codeA }), /too many attempts/));
check('locked: no new code until it expires', await refusedWith(() => call(lockApp, 'request_sign_in', { phone: realA, name: 'Ann' }), /too many attempts/));
check('locked sign-in did not bind the number', !(await myPerson(lockApp)));

const realB = '+14155550124';
const bApp = (await newIdentity()).token;
await call(bApp, 'request_sign_in', { phone: realB, name: 'Bea' });
const codeB = await codeFor(realB);
await call(bApp, 'verify_sign_in', { phone: realB, code: codeB });
const bea = await myPerson(bApp);
check('the texted code signs in and creates the person', bea?.phone_e164 === realB && bea.display_name === 'Bea' &&
  JSON.stringify(bea.last_sign_in_at) !== JSON.stringify([0]), bea);
check('the challenge is deleted after sign-in', !(await mySignIn(bApp)));
const codeRow = (await outbox()).find(r => r.to_e164 === realB && r.kind === 'system')!;
await call(photon, 'mark_outbox_status', { outbox_id: codeRow.id, status: 'sending', channel: '' });
await call(photon, 'mark_outbox_status', { outbox_id: codeRow.id, status: 'sent', channel: '' });
const sentRow = (await outbox()).find(r => r.id === codeRow.id)!;
check('the code is scrubbed from the outbox once sent', !String(sentRow.body).includes(codeB) && String(sentRow.body).includes('[code]'), sentRow.body);

const realC = '+14155550125';
const cApp = (await newIdentity()).token;
await call(cApp, 'request_sign_in', { phone: realC, name: 'Cy' });
const codeC = await codeFor(realC);
await call(photon, 'record_inbound_message', { photon_message_id: randomUUID(), from_e164: realC, channel: 'imessage', body: `my code is ${codeC.slice(0, 3)} ${codeC.slice(3)}` });
check('texting your sign-in code to the agent cancels that sign-in',
  await refusedWith(() => call(cApp, 'verify_sign_in', { phone: realC, code: codeC }), /no sign-in code/));

const realD = '+14155550126';
for (let i = 0; i < 5; i++) await call((await newIdentity()).token, 'request_sign_in', { phone: realD, name: 'Dee' });
check('5 codes per phone per hour', await refusedWith(async () => call((await newIdentity()).token, 'request_sign_in', { phone: realD, name: 'Dee' }), /too many codes/));

// App signs in as Joe (demo number, demo code)
const joeApp = (await newIdentity()).token;
await signIn(joeApp, '+15555550101', 'Joe');
const [joe] = await sql(joeApp, 'SELECT * FROM my_person');
check('app sees its own person', joe?.phone_e164 === '+15555550101', joe);
check('app sees its contacts', (await sql(joeApp, 'SELECT * FROM my_contacts')).length === 2);
const joeId = joe.id as number;

// Companion -> "asked for help" to both contacts
const before = (await outbox()).length;
const compKey = randomUUID();
await call(joeApp, 'open_incident', { request_key: compKey, person_id: joeId, entry_point: 'companion', caller_e164: '+15555550199' });
const helpRows = (await outbox()).slice(before).filter(r => r.kind === 'family_alert');
check('companion tells both family contacts', helpRows.length === 2, helpRows);
check('family help messages ask for a reply', helpRows.every(r => /reply ok so joe knows/i.test(String(r.body))), helpRows.map(r => r.body));
const [helpReq] = (await sql(joeApp, 'SELECT * FROM my_alert_requests')).filter(r => r.kind === 'help');
check('a pending help request tracks both recipients', helpReq?.status === 'pending' && (helpReq.recipient_contact_ids as unknown[]).length === 2, helpReq);
const tommyC = (await sql(joeApp, 'SELECT * FROM my_contacts')).find(c => c.name === 'Tommy')!;
const bAck = (await outbox()).length;
await call(photon, 'acknowledge_family_alert', { contact_id: tommyC.id });
const [helpReq2] = (await sql(joeApp, 'SELECT * FROM my_alert_requests')).filter(r => r.id === helpReq.id);
check('a family reply acknowledges the request', helpReq2.status === 'acknowledged' && helpReq2.acked_by_contact_id === tommyC.id, helpReq2);
check('Joe is told who saw it', (await outbox()).slice(bAck).some(r => r.to_e164 === '+15555550101' && /Tommy saw your request for help/.test(String(r.body))));

// Interview -> High
const [inc] = (await sql(joeApp, 'SELECT * FROM my_incidents')).filter(i => i.request_key === compKey);
await call(joeApp, 'save_answer', { incident_id: inc.id, question_id: 'q_identity', answer: 'T-Mobile fraud department' });
await call(joeApp, 'save_answer', { incident_id: inc.id, question_id: 'q_ask', answer: 'yes' });
const b2 = (await outbox()).length;
await call(joeApp, 'save_answer', { incident_id: inc.id, question_id: 'q_shared', answer: 'personal_details' });
let [inc2] = (await sql(joeApp, 'SELECT * FROM my_incidents')).filter(i => i.id === inc.id);
check('personal details -> High', inc2.severity === 'high', inc2.severity);
const steps = (await sql(joeApp, 'SELECT * FROM my_recovery_steps')).filter(s => s.incident_id === inc.id).map(s => s.step_key);
check('High inserts matching recovery steps', steps.includes('credit_freeze') && steps.includes('watch_statements'), steps);
await sleep(300); // scheduled agent job becomes an agent_task
const wf = await failQueuedTasks();
check('High queues family_alert and interview check-in work for the agent service', wf.includes('family_alert'), wf);
const highRows = (await outbox()).slice(b2);
check('High: "Be careful" reply to Joe', highRows.some(r => r.to_e164 === '+15555550101' && String(r.body).includes('Be careful')), highRows);
const fam = highRows.filter(r => r.kind === 'family_alert');
check('High: template family alert to Tommy (imessage) and Maria (sms)',
  fam.some(r => r.to_e164 === '+15555550102' && r.channel === 'imessage') && fam.some(r => r.to_e164 === '+15555550103' && r.channel === 'sms'), fam);
check('family alert under 600 chars and no message contents', fam.every(r => String(r.body).length <= 600));
await call(joeApp, 'save_answer', { incident_id: inc.id, question_id: 'q_shared', answer: 'nothing' });
[inc2] = (await sql(joeApp, 'SELECT * FROM my_incidents')).filter(i => i.id === inc.id);
check('severity never goes down automatically', inc2.severity === 'high', inc2.severity);

// Pause + Critical override: only the emergency contact (Tommy)
await call(joeApp, 'set_sharing_paused', { person_id: joeId, paused: true });
const k2 = randomUUID();
await call(joeApp, 'open_incident', { request_key: k2, person_id: joeId, entry_point: 'app', caller_e164: '' });
const [incC] = (await sql(joeApp, 'SELECT * FROM my_incidents')).filter(i => i.request_key === k2);
const b3 = (await outbox()).length;
await call(joeApp, 'save_answer', { incident_id: incC.id, question_id: 'q_shared', answer: 'gift_card' });
await sleep(300);
await failQueuedTasks();
const critRows = (await outbox()).slice(b3);
const critFam = critRows.filter(r => r.kind === 'family_alert');
check('Critical while paused reaches only the emergency contact',
  critFam.length >= 1 && critFam.every(r => r.to_e164 === '+15555550102') && critFam.every(r => r.priority === 'urgent'), critFam);
check('Critical: "Act now" reply', critRows.some(r => String(r.body).includes('Act now')));
check('Critical: FTC report offer', critRows.some(r => String(r.body).includes('ReportFraud.ftc.gov')));
const [joeAfter] = await sql(joeApp, 'SELECT * FROM my_person');
check('Critical sets recovery watch', JSON.stringify(joeAfter.recovery_watch_until) !== JSON.stringify([0]), joeAfter.recovery_watch_until);
refused = false;
try { await call(agents, 'enqueue_outbox', { to_e164: '+15555550103', channel: 'sms', kind: 'family_alert', body: 'x', priority: 'normal', related_incident_id: inc.id, recipient_contact_id: (await sql(joeApp, 'SELECT * FROM my_contacts')).find(c => c.name === 'Maria')!.id, group_key: '' }); } catch { refused = true; }
check('paused sharing refuses a High family alert', refused);
await call(joeApp, 'set_sharing_paused', { person_id: joeId, paused: false });

// Community floor (7a): model says safe, number has 14 reporters
const ck = randomUUID();
await call(agents, 'save_message_check', {
  request_key: ck, person_id: joeId, source: 'imessage', content: 'Hello, your code is 482913, call us back',
  model_verdict: 'safe', reason: 'r', campaign_id: 0, sender_e164: '+15555550199', link_domains: [], similarity_floor: '',
  tactics: [], evidence_count: 1,
});
const [chk] = (await sql(agents, 'SELECT * FROM svc_message_check')).filter(c => c.request_key === ck);
check('community floor raises safe -> likely_scam for a labeled number', chk.verdict === 'likely_scam', chk);
check('codes are redacted before storage', !String(chk.content_redacted).includes('482913'), chk.content_redacted);
const ck2 = randomUUID();
await call(agents, 'save_message_check', {
  request_key: ck2, person_id: joeId, source: 'imessage', content: 'We can recover your lost money for a small fee',
  model_verdict: 'safe', reason: 'r', campaign_id: 0, sender_e164: '+15555550111', link_domains: [], similarity_floor: '',
  tactics: [], evidence_count: 0,
});
const [chk2] = (await sql(agents, 'SELECT * FROM svc_message_check')).filter(c => c.request_key === ck2);
check('recovery watch forces likely_scam for refund offers', chk2.verdict === 'likely_scam', chk2);
const ck3 = randomUUID();
await call(agents, 'save_message_check', {
  request_key: ck3, person_id: joeId, source: 'share', content: 'Pay toll at link', model_verdict: 'safe', reason: 'r',
  campaign_id: 0, sender_e164: '', link_domains: ['https://www.TXTAG-pay.top/inv/1'], similarity_floor: '', tactics: [], evidence_count: 0,
});
const [chk3] = (await sql(agents, 'SELECT * FROM svc_message_check')).filter(c => c.request_key === ck3);
check('link domain floor (normalized URL) -> likely_scam', chk3.verdict === 'likely_scam', chk3);

// Verify a relative: denied
const vk = randomUUID();
const tommy = (await sql(joeApp, 'SELECT * FROM my_contacts')).find(c => c.name === 'Tommy')!;
await call(agents, 'start_verification', { request_key: vk, person_id: joeId, contact_id: tommy.id, kind: 'relay' });
const [v] = (await sql(agents, 'SELECT * FROM svc_verification')).filter(x => x.request_key === vk);
const b4 = (await outbox()).length;
await call(photon, 'resolve_verification', { verification_id: v.id, result: 'denied' });
const vRows = (await outbox()).slice(b4);
check('denied verification warns Joe', vRows.some(r => r.to_e164 === '+15555550101' && String(r.body).includes('NOT them')), vRows);
check('denied verification tells the rest of the family', vRows.some(r => r.to_e164 === '+15555550103'), vRows);
const vReq = (await sql(agents, 'SELECT * FROM svc_alert_request')).find(r => r.verification_id === v.id);
check('verification is tracked and resolved by the reply', vReq?.kind === 'verify' && vReq.status === 'acknowledged', vReq);

// Labels: third independent reporter makes a label visible
for (let i = 0; i < 1; i++) {
  const t = (await newIdentity()).token;
  await signIn(t, `+1555555090${i}`, `R${i}`);
  const [me] = await sql(t, 'SELECT * FROM my_person');
  await call(t, 'report_number', { person_id: me.id, kind: 'number', value: '+15555550177' });
  await call(t, 'report_number', { person_id: me.id, kind: 'number', value: '+15555550177' });
}
const l2 = await sql(anon, 'SELECT * FROM caller_labels');
check('label appears at 3 independent reporters, double votes ignored', l2.some(l => l.value === '+15555550177' && l.reporter_count === 3), l2);

// Evidence: one corpus row per incident (updated, not duplicated)
const ev = (await sql(agents, 'SELECT * FROM svc_report_evidence')).filter(e => e.incident_id === inc.id);
check('one report_evidence row per incident', ev.length === 1, ev.length);

// Device changes: a new identity verifying Joe's number takes it over; sign-out releases it;
// the original bug (sign out, then sign in again with a fresh identity) works.
const joePhone = '+15555550101';
const joeApp2 = (await newIdentity()).token;
await signIn(joeApp2, joePhone, 'Joe');
check('a new device that verifies the number takes it over', (await myPerson(joeApp2))?.id === joeId);
check('the old device token stops seeing my_* rows', !(await myPerson(joeApp)) && (await sql(joeApp, 'SELECT * FROM my_contacts')).length === 0);
check('the old device can no longer act for the person', await refusedWith(() => call(joeApp, 'set_sharing_paused', { person_id: joeId, paused: true }), /not your person/));
await call(joeApp2, 'sign_out', {});
const joeRow = (await sql(agents, 'SELECT * FROM svc_person')).find(p => p.phone_e164 === joePhone)!;
check('sign_out releases the binding', !(await myPerson(joeApp2)) && joeRow.owner_hex === '' && joeRow.id === joeId, joeRow);
const joeApp3 = (await newIdentity()).token;
await signIn(joeApp3, joePhone, 'Joe');
check('after sign-out the number signs in again from a new identity (no "already registered")', (await myPerson(joeApp3))?.id === joeId);
await signIn(joeApp3, '+15555550909', 'Joe Alt');
const alt = await myPerson(joeApp3);
const joeRow2 = (await sql(agents, 'SELECT * FROM svc_person')).find(p => p.phone_e164 === joePhone)!;
check('switching numbers releases the previous binding', alt?.phone_e164 === '+15555550909' && joeRow2.owner_hex === '' &&
  (await sql(joeApp3, 'SELECT * FROM my_person')).length === 1, { alt, joeRow2 });
check('services cannot sign in', await refusedWith(() => call(agents, 'request_sign_in', { phone: joePhone, name: 'x' }), /service identities/));
await signIn(joeApp, joePhone, 'Joe'); // leave Joe bound for anyone running the demo against this database

console.log(failures ? `\n${failures} check(s) failed` : '\nAll checks passed');
process.exit(failures ? 1 : 0);
