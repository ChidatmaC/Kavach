// Loads shared/seed/demo.json into SpacetimeDB (admin identity). Safe to re-run after demo_reset.
import { readFileSync } from 'node:fs';
import { call, tokenFor } from './lib/stdb';

const seed = JSON.parse(readFileSync(new URL('../shared/seed/demo.json', import.meta.url), 'utf8'));
const admin = tokenFor('admin');

export async function runSeed() {
  for (const c of seed.campaigns) await call(admin, 'admin_seed_campaign', c);
  for (const p of seed.persons) {
    await call(admin, 'admin_seed_person', {
      phone: p.phone_e164, name: p.display_name, critical_overrides_pause: p.critical_overrides_pause,
      practice_consent: p.practice_consent, tz_offset_minutes: p.tz_offset_minutes, family_code_word: seed.family_code_word,
    });
  }
  for (const c of seed.contacts) {
    await call(admin, 'admin_seed_contact', {
      person_phone: c.person_phone, name: c.name, phone: c.phone_e164, relationship: c.relationship, channel: c.channel,
      is_emergency_contact: c.is_emergency_contact, is_app_user: c.is_app_user, consent_status: c.consent_status,
    });
  }
  for (const r of seed.community_reports) {
    await call(admin, 'admin_seed_report', { kind: r.kind, value: r.value, campaign_slug: r.campaign_slug ?? '', reporter_count: r.reporter_count });
  }
  for (const e of seed.report_evidence) {
    await call(admin, 'admin_seed_evidence', {
      source: e.source, channel: e.channel, sender_e164: e.sender_e164 ?? '', links: e.links, claimed_identity: e.claimed_identity ?? '',
      tactics: e.tactics, text_redacted: e.text_redacted, verdict: e.verdict, campaign_slug: e.campaign_slug ?? '',
    });
  }
  console.log(`Seeded ${seed.persons.length} persons, ${seed.contacts.length} contacts, ${seed.campaigns.length} campaigns, ${seed.community_reports.length} reports, ${seed.report_evidence.length} evidence rows.`);
}

if (import.meta.url === `file://${process.argv[1]}`) await runSeed();
