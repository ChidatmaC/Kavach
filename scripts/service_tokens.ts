// Creates one SpacetimeDB identity per service role and binds it with claim_service.
// Writes .spacetime-tokens.json (gitignored) and prints the matching .env lines.
import { writeFileSync, existsSync, readFileSync } from 'node:fs';
import { TOKENS_FILE, call, newIdentity } from './lib/stdb';

const key = process.env.SERVICE_CLAIM_KEY;
if (!key) throw new Error('SERVICE_CLAIM_KEY missing from .env');
const tokens: Record<string, string> = existsSync(TOKENS_FILE) ? JSON.parse(readFileSync(TOKENS_FILE, 'utf8')) : {};
for (const role of ['admin', 'agents', 'photon']) {
  if (!tokens[role]) tokens[role] = (await newIdentity()).token;
  await call(tokens[role], 'claim_service', { role, key });
  console.log(`SPACETIME_TOKEN_${role.toUpperCase()}=${tokens[role]}`);
}
writeFileSync(TOKENS_FILE, JSON.stringify(tokens, null, 2));
console.error(`\nSaved ${TOKENS_FILE}. Services read tokens from there or from the env lines above.`);
