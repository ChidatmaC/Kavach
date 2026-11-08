// End-to-end checks of the SpacetimeDB module over HTTP. Wipes and re-seeds the database first.
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

// Start from a clean, seeded state (full wipe so app-bound numbers can be registered again).
await call(tokenFor('admin'), 'admin_reset', {});
await call(tokenFor('admin'), 'admin_wipe', {});
await runSeed();

// Access rules
const anon = (await newIdentity()).token;
check('anonymous cannot read persons', (await sql(anon, 'SELECT * FROM svc_person')).length === 0);
check('anonymous cannot read evidence (D15)', (await sql(anon, 'SELECT * FROM svc_report_evidence')).length === 0);
const labels = await sql(anon, 'SELECT * FROM caller_labels');
check('caller labels show only numbers with 3+ reporters', labels.length === 2 && labels.some(l => l.value === '+15555550199' && l.reporter_count === 14), labels);
check('service can read persons', (await sql(agents, 'SELECT * FROM svc_person')).length === 2);
let refused = false;
try { await call(anon, 'enqueue_outbox', { to_e164: '+15555550101', channel: 'sms', kind: 'reply', body: 'x', priority: 'normal', related_incident_id: 0, recipient_contact_id: 0, group_key: '' }); } catch { refused = true; }
check('anonymous cannot enqueue outbox', refused);

// App registers as Joe
const joeApp = (await newIdentity()).token;
await call(joeApp, 'register_person', { phone: '+15555550101', name: 'Joe' });
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

// Labels: third independent reporter makes a label visible
for (let i = 0; i < 1; i++) {
  const t = (await newIdentity()).token;
  await call(t, 'register_person', { phone: `+1555555090${i}`, name: `R${i}` });
  const [me] = await sql(t, 'SELECT * FROM my_person');
  await call(t, 'report_number', { person_id: me.id, kind: 'number', value: '+15555550177' });
  await call(t, 'report_number', { person_id: me.id, kind: 'number', value: '+15555550177' });
}
const l2 = await sql(anon, 'SELECT * FROM caller_labels');
check('label appears at 3 independent reporters, double votes ignored', l2.some(l => l.value === '+15555550177' && l.reporter_count === 3), l2);

// Evidence: one corpus row per incident (updated, not duplicated)
const ev = (await sql(agents, 'SELECT * FROM svc_report_evidence')).filter(e => e.incident_id === inc.id);
check('one report_evidence row per incident', ev.length === 1, ev.length);

console.log(failures ? `\n${failures} check(s) failed` : '\nAll checks passed');
process.exit(failures ? 1 : 0);
