// Test doubles: a scriptable gateway, an in-memory outbox store that mimics mark_outbox_status,
// and a manual clock.
import type { Gateway, InboundHandlerFn, SendResult, TextChannel } from '../src/gateway/types';
import type { OutboxStore } from '../src/outbox';
import type { OutboxRow } from '../src/stdb';

export interface SentRecord {
  to: string[];
  body: string;
  channel: TextChannel;
  group?: string;
}

export class FakeGateway implements Gateway {
  readonly name = 'fake';
  sent: SentRecord[] = [];
  attempts: SentRecord[] = [];
  /** Return true to make this attempt throw. */
  failWhen: (r: SentRecord) => boolean = () => false;
  groups = true;
  iMessage = new Map<string, boolean>();
  handler: InboundHandlerFn | null = null;

  async start(onMessage: InboundHandlerFn): Promise<void> {
    this.handler = onMessage;
  }
  async stop(): Promise<void> {
    this.handler = null;
  }
  async sendToNumber(to: string, body: string, channel: TextChannel): Promise<SendResult> {
    const rec = { to: [to], body, channel };
    this.attempts.push(rec);
    if (this.failWhen(rec)) throw new Error('fake send failure');
    this.sent.push(rec);
    return { channel };
  }
  async sendToGroup(members: string[], body: string, groupKey: string): Promise<SendResult> {
    const rec = { to: members, body, channel: 'imessage' as const, group: groupKey };
    this.attempts.push(rec);
    if (this.failWhen(rec)) throw new Error('fake group failure');
    this.sent.push(rec);
    return { channel: 'imessage' };
  }
  supportsGroups(): boolean {
    return this.groups;
  }
  async isIMessage(address: string): Promise<boolean | undefined> {
    return this.iMessage.get(address);
  }
}

export class ManualClock {
  constructor(public t = 1_800_000_000_000) {}
  now(): number {
    return this.t;
  }
  advance(ms: number): void {
    this.t += ms;
  }
}

let nextId = 1;
export function row(p: Partial<OutboxRow> = {}): OutboxRow {
  const id = p.id ?? nextId++;
  return {
    id, to_e164: '+15555550101', group_key: '', channel: 'imessage', kind: 'reply', body: `message ${id}`,
    priority: 'normal', related_incident_id: 0, recipient_contact_id: 0, status: 'queued', attempts: 0,
    created_at: 1_000_000 + id, ...p,
  };
}

export class MemoryStore implements OutboxStore {
  rows = new Map<number, OutboxRow>();
  opted = new Set<string>();
  marks: Array<{ id: number; status: string; channel: string }> = [];

  constructor(rows: OutboxRow[] = []) {
    for (const r of rows) this.rows.set(r.id, { ...r });
  }
  async queuedOutbox(): Promise<OutboxRow[]> {
    return [...this.rows.values()].filter(r => r.status === 'queued').map(r => ({ ...r }));
  }
  async outboxByStatus(status: string): Promise<OutboxRow[]> {
    return [...this.rows.values()].filter(r => r.status === status).map(r => ({ ...r }));
  }
  async outboxRow(id: number): Promise<OutboxRow | null> {
    const r = this.rows.get(id);
    return r ? { ...r } : null;
  }
  async markOutbox(id: number, status: string, channel = ''): Promise<void> {
    this.marks.push({ id, status, channel });
    const r = this.rows.get(id);
    if (!r) throw new Error('unknown outbox row');
    if (r.status === 'sent') return; // same as the module
    r.attempts = status === 'sending' ? r.attempts + 1 : r.attempts;
    r.status = status;
    if (channel) r.channel = channel;
  }
  async optOuts(): Promise<Set<string>> {
    return new Set(this.opted);
  }
}

export const noPush = { push: async () => ({ sent: true }) };
