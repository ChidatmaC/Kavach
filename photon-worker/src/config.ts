// Worker configuration. Reads the repo-root .env (secrets live only in env, spec 12),
// then the service token from SPACETIME_TOKEN_PHOTON or the root .spacetime-tokens.json.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

export type GatewayKind = 'console' | 'photon';

export interface Config {
  appName: string;
  spacetimeUri: string;
  spacetimeDb: string;
  spacetimeToken: string;
  agentUrl: string;
  agentToken: string;
  agentTimeoutMs: number;
  gateway: GatewayKind;
  photonProjectId: string;
  photonProjectSecret: string;
  photonLine: string;
  healthPort: number;
  pollMs: number;
  /** A contact's free-text reply counts as a family-thread reply this long after we last texted them. */
  familyReplyWindowMs: number;
  /** Extra domains allowed as tappable links (the app's own site). */
  allowedLinkDomains: string[];
}

let envLoaded = false;
export function loadEnv(): void {
  if (envLoaded) return;
  envLoaded = true;
  const path = resolve(REPO_ROOT, '.env');
  if (existsSync(path)) dotenv.config({ path, quiet: true } as dotenv.DotenvConfigOptions);
}

export function tokenFor(role: string, env: NodeJS.ProcessEnv = process.env): string {
  const key = `SPACETIME_TOKEN_${role.toUpperCase()}`;
  if (env[key]) return env[key]!;
  const file = resolve(REPO_ROOT, '.spacetime-tokens.json');
  if (existsSync(file)) {
    const t = JSON.parse(readFileSync(file, 'utf8'))[role];
    if (t) return t as string;
  }
  throw new Error(`no SpacetimeDB token for role "${role}"; run "npm run tokens" at the repo root`);
}

export function loadConfig(overrides: Partial<Config> = {}): Config {
  loadEnv();
  const env = process.env;
  const gateway = (env.MESSAGING_GATEWAY ?? 'console').toLowerCase();
  if (gateway !== 'console' && gateway !== 'photon') throw new Error(`MESSAGING_GATEWAY must be console or photon, got ${gateway}`);
  const base: Config = {
    appName: env.APP_DISPLAY_NAME || 'Kavach',
    spacetimeUri: env.SPACETIME_URI || 'http://127.0.0.1:3000',
    spacetimeDb: env.SPACETIME_DB_NAME || 'kavach',
    spacetimeToken: overrides.spacetimeToken ?? tokenFor('photon'),
    agentUrl: (env.AGENT_SERVICE_URL || 'http://127.0.0.1:8088').replace(/\/$/, ''),
    agentToken: env.AGENT_SERVICE_TOKEN || '',
    agentTimeoutMs: Number(env.AGENT_TIMEOUT_MS || 20_000),
    gateway,
    photonProjectId: env.PHOTON_PROJECT_ID || '',
    photonProjectSecret: env.PHOTON_API_KEY || '',
    photonLine: env.PHOTON_AGENT_LINE || '',
    healthPort: Number(env.PHOTON_HEALTH_PORT || 8090),
    pollMs: Number(env.OUTBOX_POLL_MS || 500),
    familyReplyWindowMs: Number(env.FAMILY_REPLY_WINDOW_MINUTES || 60) * 60_000,
    allowedLinkDomains: (env.APP_LINK_DOMAINS || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean),
  };
  return { ...base, ...overrides };
}
