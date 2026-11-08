// Erases ALL users and scam data, then loads scam-call demo data (shared/seed/scam_calls.json):
// campaigns, reported scam caller numbers, reported phrases and call-script evidence. No users:
// people sign in with a code (demo 555 numbers accept 000000 in DEMO_MODE).
import { readFileSync } from 'node:fs';
import { call, sql, tokenFor } from './lib/stdb';

const seed = JSON.parse(readFileSync(new URL('../shared/seed/scam_calls.json', import.meta.url), 'utf8'));
const admin = tokenFor('admin');

await call(admin, 'admin_reset', {});   // incidents, checks, reports, votes, evidence, campaigns, outbox...
await call(admin, 'admin_wipe', {});    // all persons (users and their sign-ins)

for (const c of seed.campaigns) await call(admin, 'admin_seed_campaign', c);
for (const r of seed.scam_callers) {
  await call(admin, 'admin_set_report', { kind: 'number', value: r.value, campaign_slug: r.campaign_slug, reporter_count: r.reporter_count });
}
for (const r of seed.phrases) {
  await call(admin, 'admin_set_report', { kind: 'phrase', value: r.value, campaign_slug: r.campaign_slug, reporter_count: r.reporter_count });
}
for (const e of seed.call_evidence) {
  await call(admin, 'admin_seed_evidence', {
    source: 'call', channel: 'call', sender_e164: e.sender_e164, links: [], claimed_identity: e.claimed_identity,
    tactics: e.tactics, text_redacted: e.text_redacted, verdict: e.verdict, campaign_slug: e.campaign_slug,
  });
}

const agents = tokenFor('agents');
const count = async (q: string) => (await sql(agents, q)).length;
console.log(`persons: ${await count('SELECT * FROM svc_person')}, campaigns: ${await count('SELECT * FROM campaign')}, ` +
  `reports: ${await count('SELECT * FROM svc_community_report')}, caller labels: ${await count('SELECT * FROM caller_labels')}, ` +
  `evidence: ${await count('SELECT * FROM svc_report_evidence')}`);
