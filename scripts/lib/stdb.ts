// Minimal SpacetimeDB HTTP client for scripts (mirrors docs/CONTRACTS.md).
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import 'dotenv/config';

export const URI = process.env.SPACETIME_URI ?? 'http://127.0.0.1:3000';
export const DB = process.env.SPACETIME_DB_NAME ?? 'kavach';
export const TOKENS_FILE = resolve(process.cwd(), '.spacetime-tokens.json');

export async function newIdentity(): Promise<{ identity: string; token: string }> {
  const res = await fetch(`${URI}/v1/identity`, { method: 'POST' });
  if (!res.ok) throw new Error(`identity: ${res.status} ${await res.text()}`);
  return res.json() as Promise<{ identity: string; token: string }>;
}

export function tokenFor(role: string): string {
  const envKey = `SPACETIME_TOKEN_${role.toUpperCase()}`;
  if (process.env[envKey]) return process.env[envKey]!;
  if (existsSync(TOKENS_FILE)) {
    const t = JSON.parse(readFileSync(TOKENS_FILE, 'utf8'))[role];
    if (t) return t;
  }
  throw new Error(`no token for ${role}; run "npm run tokens" first`);
}

export async function call(token: string, reducer: string, args: Record<string, unknown>): Promise<void> {
  const res = await fetch(`${URI}/v1/database/${DB}/call/${reducer}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${reducer}: ${res.status} ${await res.text()}`);
}

/** Runs SQL and returns rows as objects keyed by column name. */
export async function sql(token: string, query: string): Promise<Record<string, unknown>[]> {
  const res = await fetch(`${URI}/v1/database/${DB}/sql`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}` },
    body: query,
  });
  if (!res.ok) throw new Error(`sql: ${res.status} ${await res.text()}`);
  const [result] = (await res.json()) as Array<{ schema: { elements: Array<{ name: { some: string } }> }; rows: unknown[][] }>;
  const names = result.schema.elements.map(e => e.name.some);
  return result.rows.map(r => Object.fromEntries(r.map((v, i) => [names[i], v])));
}
