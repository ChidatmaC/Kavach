// Local text commands, matched before the router (spec 9). Pure: no I/O.
//
// Whole-message matches only (after trimming case, spacing and trailing punctuation), so
// "no way, is this a scam?" goes to the router while "No." is a verification answer.

export type Command =
  | { type: 'verify'; name: string }
  | { type: 'confirm' } // yes / it's me / confirmed
  | { type: 'deny' } // no / not me
  | { type: 'ack' } // I'm calling / on it
  | { type: 'pause' }
  | { type: 'resume' }
  | { type: 'stop' }
  | { type: 'start' } // opt back in after stop
  | { type: 'help' }
  | { type: 'join'; name: string };

export function normalize(text: string): string {
  return text
    .normalize('NFKC')
    .replace(/[‘’ʼ]/g, "'")
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[\s"'(]+|[\s.!?,"')]+$/g, '')
    .trim();
}

const CONFIRM = new Set([
  'yes', 'y', 'yes it\'s me', 'yes its me', 'it\'s me', 'its me', 'it is me', 'yes it is me', 'confirmed', 'confirm',
  'yes confirmed', 'that was me', 'yes that was me', 'yes that\'s me', 'that\'s me',
]);
const DENY = new Set([
  'no', 'n', 'not me', 'no not me', 'no it\'s not me', 'no its not me', 'it\'s not me', 'its not me', 'wasn\'t me',
  'it wasn\'t me', 'no it wasn\'t me', 'no that wasn\'t me', 'that wasn\'t me', 'no it was not me', 'it was not me', 'nope',
]);
const ACK = /^(?:(?:i'?m|i am|im) (?:calling|on it|calling (?:him|her|them|now))|on it|calling (?:now|him|her|them)|i'll call(?: (?:him|her|them))?(?: now)?)$/;
// CTIA opt-out and opt-in keywords; single word only.
const STOP = new Set(['stop', 'stopall', 'stop all', 'unsubscribe', 'cancel', 'end', 'quit']);
const START = new Set(['start', 'unstop', 'resubscribe']);
const HELP = new Set(['help', 'info', '?', 'commands']);

export function parseCommand(text: string): Command | null {
  const t = normalize(text);
  if (!t) return null;
  const verify = /^verify\s+(.{1,60})$/.exec(t);
  if (verify) return { type: 'verify', name: titleCase(verify[1].trim()) };
  const join = /^join\s+(.{1,60})$/.exec(t);
  if (join) return { type: 'join', name: titleCase(join[1].trim()) };
  if (CONFIRM.has(t)) return { type: 'confirm' };
  if (DENY.has(t)) return { type: 'deny' };
  if (ACK.test(t)) return { type: 'ack' };
  if (t === 'pause') return { type: 'pause' };
  if (t === 'resume' || t === 'unpause') return { type: 'resume' };
  if (STOP.has(t)) return { type: 'stop' };
  if (START.has(t)) return { type: 'start' };
  if (HELP.has(t)) return { type: 'help' };
  return null;
}

function titleCase(s: string): string {
  return s.replace(/\b\p{L}/gu, c => c.toUpperCase());
}

/** Same name, ignoring case and spacing ("tommy" matches "Tommy"). */
export function sameName(a: string, b: string): boolean {
  return normalize(a) === normalize(b);
}
