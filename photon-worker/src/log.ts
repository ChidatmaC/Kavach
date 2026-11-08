// Structured JSON logs (spec 13). Never log message bodies, codes or full phone numbers.
type Level = 'debug' | 'info' | 'warn' | 'error';
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

let minLevel: Level = (process.env.LOG_LEVEL as Level) in ORDER ? (process.env.LOG_LEVEL as Level) : 'info';
let sink: (line: string) => void = line => process.stderr.write(line + '\n');

/** Fields that may carry message content are dropped even if a caller passes them. */
const FORBIDDEN = new Set(['body', 'text', 'content', 'message', 'utterance', 'image_base64']);

export function setLogSink(fn: (line: string) => void, level: Level = minLevel): void {
  sink = fn;
  minLevel = level;
}

/** "+15555550101" -> "***0101": enough to correlate, not enough to identify. */
export function maskPhone(e164: string): string {
  return e164 ? `***${e164.slice(-4)}` : '';
}

function emit(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  if (ORDER[level] < ORDER[minLevel]) return;
  const clean: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(fields)) {
    if (FORBIDDEN.has(k)) continue;
    clean[k] = v instanceof Error ? v.message : v;
  }
  sink(JSON.stringify({ ts: new Date().toISOString(), level, component: 'photon-worker', event, ...clean }));
}

export const log = {
  debug: (event: string, fields?: Record<string, unknown>) => emit('debug', event, fields),
  info: (event: string, fields?: Record<string, unknown>) => emit('info', event, fields),
  warn: (event: string, fields?: Record<string, unknown>) => emit('warn', event, fields),
  error: (event: string, fields?: Record<string, unknown>) => emit('error', event, fields),
};
