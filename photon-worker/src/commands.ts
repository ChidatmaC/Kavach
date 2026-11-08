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
  if (forwardWrapper(text)) return null; // "Forwarded message: \"verify Tommy\"" is someone else's text
  // A pasted text in quotes ("verify your account...") is not the person asking us to verify or join.
  const quoted = /^\s*["“‘']/.test(text);
  const verify = quoted ? null : /^verify\s+(.{1,60})$/.exec(t);
  if (verify) return { type: 'verify', name: titleCase(verify[1].trim()) };
  const join = quoted ? null : /^join\s+(.{1,60})$/.exec(t);
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

// A family member's short "seen it" reply to a help request or scam alert. Acknowledgement only:
// never relayed to the rest of the family and never scam-checked.
const SHORT_ACK = new Set([
  'ok', 'okay', 'k', 'kk', 'ok thanks', 'okay thanks', 'ok thank you', 'got it', 'got it thanks', 'seen', 'seen it',
  'saw it', 'thanks', 'thank you', 'thx', 'ty', 'will call', 'will do', 'will call now', 'will call him', 'will call her',
  'will call them', 'on my way', 'omw', 'on the way', 'roger', '👍', '👌', '🙏', '❤️', '✅',
]);

export function isShortAck(text: string): boolean {
  const t = normalize(text).replace(/[.!,]+/g, '').replace(/\s+/g, ' ').trim();
  if (!t) return false;
  if (SHORT_ACK.has(t)) return true;
  // Emoji-only replies (a thumbs up in any skin tone, a heart...).
  return /^[\p{Extended_Pictographic}\p{Emoji_Modifier}\u{FE0F}\u{200D}\s]+$/u.test(t);
}

function titleCase(s: string): string {
  return s.replace(/\b\p{L}/gu, c => c.toUpperCase());
}

/** Same name, ignoring case and spacing ("tommy" matches "Tommy"). */
export function sameName(a: string, b: string): boolean {
  return normalize(a) === normalize(b);
}

// --- forwarded-message wrapper (CONTRACTS section 7; agents/kavach/workflows/forward.py is the reference) ---
//
//   Forwarded message:
//   From: +1 555 555 0144      (optional)
//   "<the message they received>"
//
// Markers (any case, with or without a colon): Forwarded message, Forwarded, Fwd, Fw, Check this,
// Check this message, Is this a scam, Scam?. A marker must be followed by ":", "?", "-", a newline, an
// opening quote or the end of the text, so "Check this out" is not a wrapper. A wrapped text is never a
// local command or a family "seen it" reply; it always goes to the router, which scam-checks the inner text.

const QUOTES_OPEN = `"'“‘«„`;
const QUOTES_CLOSE = `"'”’»“`;
const MARKER = new RegExp(
  String.raw`^\s*[\[(<-]*\s*(?:forwarded\s+message|forwarded|fwd|fw|check\s+this\s+message|check\s+this|is\s+this\s+a\s+scam|scam)\s*[\])>]*` +
  String.raw`(?:\s*[:?\-–—]+|\s*(?=\n)|\s*(?=[${QUOTES_OPEN}])|\s*$)`,
  'i');
const FROM_LINE = /^\s*from\s*:\s*.{1,80}$/i;

export interface ForwardWrapper {
  /** The forwarded message only; empty for a bare marker ("Fwd:"), meaning the next text is the forward. */
  inner: string;
  bare: boolean;
}

export function forwardWrapper(text: string): ForwardWrapper | null {
  const m = MARKER.exec(text ?? '');
  if (!m) return null;
  const lines = text.slice(m[0].length).split('\n');
  while (lines.length && !lines[0].trim()) lines.shift();
  if (lines.length && FROM_LINE.test(lines[0])) lines.shift();
  let inner = lines.join('\n').trim();
  if (inner.length >= 2 && QUOTES_OPEN.includes(inner[0]) && QUOTES_CLOSE.includes(inner[inner.length - 1])) {
    inner = inner.slice(1, -1).trim();
  } else if (inner && QUOTES_OPEN.includes(inner[0]) && ![...inner.slice(1)].some(c => QUOTES_CLOSE.includes(c))) {
    inner = inner.slice(1).trim();
  }
  return { inner, bare: !inner };
}

/** "1" / "2" (and words for them): an answer to the router's "received, or your question?" prompt. */
const CLARIFY_ANSWER = /^\s*(?:1|2|one|two|#1|#2|option [12]|received|i received it|message|a message|it'?s a message|question|a question|my question|mine|it'?s mine|it'?s my question)\s*[.!)]*\s*$/i;
export const CLARIFY_MARKER = 'Reply 1 if you received it, 2 if it';

export function isClarifyAnswer(text: string): boolean {
  return CLARIFY_ANSWER.test((text ?? '').replace(/[‘’ʼ]/g, "'"));
}
