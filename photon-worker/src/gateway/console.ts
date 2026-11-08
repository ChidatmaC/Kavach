// Local development gateway: type inbound messages in the terminal, see outbound ones printed.
//
//   +15555550101> verify Tommy          (iMessage from Joe)
//   +15555550103:sms> stop              (SMS from Maria)
//   +15555550101> /img ./toll.png check this   (image attachment, plus optional text)
//   /fail +15555550102 2                (next 2 sends to that number fail, to watch retries)
//
// We use readline rather than the spectrum-ts terminal provider: that provider downloads a
// separate TUI binary (tuichat) and models a single chat, not many phone numbers.
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { extname } from 'node:path';
import { createInterface, type Interface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';
import type { Gateway, InboundEvent, InboundHandlerFn, SendResult, TextChannel } from './types';

const LINE = /^\s*(\+[1-9]\d{6,14})(?::(imessage|sms|rcs))?\s*>\s?(.*)$/i;

export function parseConsoleLine(line: string): Omit<InboundEvent, 'id' | 'receivedAt'> | null {
  const m = LINE.exec(line);
  if (!m) return null;
  const [, from, ch, rest] = m;
  let text = rest ?? '';
  const images: InboundEvent['images'] = [];
  const img = /^\/img\s+(\S+)\s*(.*)$/.exec(text);
  if (img) {
    const path = img[1];
    const ext = extname(path).toLowerCase();
    const mimeType = ext === '.png' ? 'image/png' : ext === '.heic' ? 'image/heic' : 'image/jpeg';
    images.push({ mimeType, base64: readFileSync(path).toString('base64') });
    text = img[2] ?? '';
  }
  return { from, channel: ((ch ?? 'imessage').toLowerCase() as TextChannel), text, images, isGroup: false };
}

export interface ConsoleGatewayOptions {
  input?: Readable;
  output?: Writable;
  /** Numbers treated as SMS-only (iMessage sends to them "fall back"). */
  smsOnly?: string[];
}

export class ConsoleGateway implements Gateway {
  readonly name = 'console';
  private rl: Interface | null = null;
  private readonly out: Writable;
  private readonly failNext = new Map<string, number>();
  private readonly smsOnly: Set<string>;

  constructor(private readonly opts: ConsoleGatewayOptions = {}) {
    this.out = opts.output ?? process.stdout;
    this.smsOnly = new Set(opts.smsOnly ?? []);
  }

  async start(onMessage: InboundHandlerFn): Promise<void> {
    this.rl = createInterface({ input: this.opts.input ?? process.stdin, terminal: false });
    this.print('console gateway ready. Type "+15555550101> verify Tommy" to simulate an inbound text.');
    this.rl.on('line', line => {
      void this.onLine(line, onMessage);
    });
  }

  private async onLine(line: string, onMessage: InboundHandlerFn): Promise<void> {
    const fail = /^\s*\/fail\s+(\+\d+)\s*(\d*)\s*$/.exec(line);
    if (fail) {
      this.failNext.set(fail[1], Number(fail[2] || 1));
      this.print(`next ${fail[2] || 1} send(s) to ${fail[1]} will fail`);
      return;
    }
    if (!line.trim()) return;
    let parsed;
    try {
      parsed = parseConsoleLine(line);
    } catch (err) {
      this.print(`could not read that: ${(err as Error).message}`);
      return;
    }
    if (!parsed) {
      this.print('format: +15555550101> message text   (or +1555...:sms> text)');
      return;
    }
    await onMessage({ ...parsed, id: `console-${randomUUID()}`, receivedAt: new Date() });
  }

  async stop(): Promise<void> {
    this.rl?.close();
    this.rl = null;
  }

  private maybeFail(to: string): void {
    const n = this.failNext.get(to) ?? 0;
    if (n > 0) {
      this.failNext.set(to, n - 1);
      throw new Error('simulated send failure');
    }
  }

  async sendToNumber(to: string, body: string, channel: TextChannel): Promise<SendResult> {
    this.maybeFail(to);
    if (channel === 'imessage' && this.smsOnly.has(to)) throw new Error('not on iMessage');
    this.print(`[${channel} -> ${to}] ${body}`);
    return { channel, providerMessageId: randomUUID() };
  }

  async sendToGroup(members: string[], body: string, groupKey: string): Promise<SendResult> {
    for (const m of members) this.maybeFail(m);
    this.print(`[imessage group ${groupKey} -> ${members.join(', ')}] ${body}`);
    return { channel: 'imessage', providerMessageId: randomUUID() };
  }

  supportsGroups(): boolean {
    return true;
  }

  async isIMessage(address: string): Promise<boolean | undefined> {
    return this.smsOnly.has(address) ? false : undefined;
  }

  private print(s: string): void {
    this.out.write(`${s}\n`);
  }
}
