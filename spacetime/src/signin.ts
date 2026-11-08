// Phone sign-in by one-time code: code generation and hashing.
//
// Modules have no WebCrypto, and ctx.random is seeded from the reducer timestamp (predictable),
// so codes are derived as SHA-256(server secret | timestamp | identity | phone | ctx.random bytes)
// and stored only as SHA-256(secret | salt | code). The secret is SERVICE_CLAIM_KEY, which never
// leaves the server, so neither the code nor its hash can be recomputed from public data.
import type { Ctx } from './lib';
import { isDemo } from './lib';

const SEC = 1_000_000n;
const MIN = 60n * SEC;
export const SIGN_IN = {
  codeTtl: 10n * MIN,
  maxAttempts: 5,
  /** Requests allowed per phone and per identity in `rateWindow`. */
  maxRequests: 5,
  rateWindow: 60n * MIN,
  /** Minimum gap between two codes for the same phone from the same identity (app resend cooldown). */
  resendCooldown: 30n * SEC,
};
/** Seeded demo personas use this range; their texts can't be delivered. */
export const DEMO_PREFIX = '+1555555';
export const DEMO_CODE = '000000';

/** With DEMO_MODE=true, numbers in the +1555555 range also accept 000000 (and get no text). */
export function isDemoNumber(ctx: Ctx, phone: string): boolean {
  return isDemo(ctx) && phone.startsWith(DEMO_PREFIX);
}

// --- SHA-256 (FIPS 180-4), small and dependency-free --------------------------------------

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function utf8(s: string): number[] {
  const out: number[] = [];
  for (const ch of s) {
    const c = ch.codePointAt(0)!;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else { out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
  }
  return out;
}

export function sha256(input: string | number[]): Uint8Array {
  const bytes = typeof input === 'string' ? utf8(input) : [...input];
  const bitLen = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  const hi = Math.floor(bitLen / 0x100000000);
  for (const word of [hi, bitLen >>> 0]) bytes.push((word >>> 24) & 255, (word >>> 16) & 255, (word >>> 8) & 255, word & 255);
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const w = new Uint32Array(64);
  const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));
  for (let off = 0; off < bytes.length; off += 64) {
    for (let i = 0; i < 16; i++) {
      const j = off + i * 4;
      w[i] = (bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3];
    }
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0; h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 8; i++) {
    out[i * 4] = h[i] >>> 24; out[i * 4 + 1] = (h[i] >>> 16) & 255; out[i * 4 + 2] = (h[i] >>> 8) & 255; out[i * 4 + 3] = h[i] & 255;
  }
  return out;
}

export function hex(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}

function secret(ctx: Ctx): string {
  return ctx.env.SERVICE_CLAIM_KEY ?? '';
}

/** A fresh 6-digit code and a per-challenge salt. */
export function newCode(ctx: Ctx, phone: string): { code: string; salt: string } {
  const noise = hex(ctx.random.fill(new Uint8Array(16)));
  const seed = sha256(`kavach-code|${secret(ctx)}|${ctx.timestamp.microsSinceUnixEpoch}|${ctx.sender.toHexString()}|${phone}|${noise}`);
  const n = ((seed[0] << 24) | (seed[1] << 16) | (seed[2] << 8) | seed[3]) >>> 0;
  return { code: String(n % 1_000_000).padStart(6, '0'), salt: hex(seed.slice(16)) };
}

export function hashCode(ctx: Ctx, salt: string, code: string): string {
  return hex(sha256(`kavach-signin|${secret(ctx)}|${salt}|${code}`));
}

/** Constant-time string compare (equal lengths only matter here). */
export function sameHash(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function signInMessage(app: string, code: string): string {
  return `${app} sign-in code: ${code}. Enter it in the ${app} app. Never share it with anyone, and ${app} will never ask you to text it back.`;
}

/** Matches the code inside a delivered sign-in text, so the outbox row can be scrubbed. */
export const SIGN_IN_BODY_RE = /sign-in code: (\d{6})\b/;

// --- helpers used by other reducers (reducer files may only export SpacetimeDB exports) ----

/** Once a sign-in text has left (sent/failed), the outbox row no longer needs the code. */
export function scrubSignInCode(body: string): string {
  return body.replace(SIGN_IN_BODY_RE, 'sign-in code: [code]');
}

/**
 * A person texted a 6-digit code that matches their own pending sign-in code (e.g. to the agent):
 * the code is no longer secret, so cancel that sign-in. Returns true if one was cancelled.
 */
export function burnSharedSignInCodes(ctx: Ctx, fromE164: string, body: string): boolean {
  const pending = [...ctx.db.signInChallenge.phone_e164.filter(fromE164)];
  if (!pending.length) return false;
  const codes = body.match(/(?<!\d)\d{3}[ -]?\d{3}(?!\d)/g) ?? [];
  let burned = false;
  for (const raw of codes) {
    const c = raw.replace(/\D/g, '');
    for (const ch of pending) {
      if (sameHash(hashCode(ctx, ch.salt, c), ch.code_hash) && ctx.db.signInChallenge.id.find(ch.id)) {
        ctx.db.signInChallenge.id.delete(ch.id);
        burned = true;
      }
    }
  }
  return burned;
}

/** Daily purge: expired challenges and old rate-limit rows. */
export function purgeSignIn(ctx: Ctx) {
  const t0 = ctx.timestamp.microsSinceUnixEpoch;
  for (const c of [...ctx.db.signInChallenge.iter()]) if (c.expires_at.microsSinceUnixEpoch <= t0) ctx.db.signInChallenge.id.delete(c.id);
  for (const r of [...ctx.db.signInRequestLog.iter()]) {
    if (r.created_at.microsSinceUnixEpoch < t0 - SIGN_IN.rateWindow) ctx.db.signInRequestLog.id.delete(r.id);
  }
}
