// Outbound delivery (spec 9 "Outbound delivery", D6, D13; spec 13 at-least-once + dedupe by id).
//
// Every 500 ms: read svc_outbox WHERE status = 'queued', order urgent-then-oldest, set `sending`,
// deliver, then `sent`. Failures go back to `queued` behind an in-memory retry gate
// (5 s, 15 s, 45 s); an iMessage row that still fails is switched to SMS once, then `failed`.
// Rows sharing a group_key go out as one iMessage group when every recipient is on iMessage.
// `push` rows go to the agent service's /push.
import type { AgentClient } from './agent';
import type { Gateway, TextChannel } from './gateway/types';
import { log, maskPhone } from './log';
import type { OutboxRow } from './stdb';
import { styleBody } from './style';

// --- pure helpers (unit-tested) ------------------------------------------------------

/** Urgent first, then oldest first, then lowest id. */
export function sortQueue(rows: OutboxRow[]): OutboxRow[] {
  return [...rows].sort((a, b) =>
    (a.priority === 'urgent' ? 0 : 1) - (b.priority === 'urgent' ? 0 : 1) ||
    a.created_at - b.created_at ||
    a.id - b.id);
}

export const BACKOFF_MS = [5_000, 15_000, 45_000] as const;

export type FailureStep =
  | { action: 'retry'; delayMs: number }
  | { action: 'fallback_sms' }
  | { action: 'fail' };

/**
 * `failures` counts failed attempts so far (1 after the first failure).
 * Initial try + 3 retries; then iMessage rows get one SMS attempt; then failed.
 */
export function nextStepAfterFailure(failures: number, channel: string, fellBack: boolean): FailureStep {
  if (fellBack) return { action: 'fail' };
  if (failures <= BACKOFF_MS.length) return { action: 'retry', delayMs: BACKOFF_MS[failures - 1] };
  if (channel === 'imessage') return { action: 'fallback_sms' };
  return { action: 'fail' };
}

/**
 * One group send only when: the gateway can do groups, 2+ recipients, every row is on
 * iMessage (stored channel and, when known, live reachability), they all carry the same
 * text, and none has already failed as part of a group.
 */
export function shouldSendAsGroup(
  rows: OutboxRow[],
  opts: { groupsSupported: boolean; iMessage: Map<string, boolean | undefined>; noGroup: Set<number> }
): boolean {
  if (!opts.groupsSupported || rows.length < 2) return false;
  if (new Set(rows.map(r => r.to_e164)).size !== rows.length) return false;
  if (rows.some(r => r.channel !== 'imessage' || opts.noGroup.has(r.id))) return false;
  if (rows.some(r => opts.iMessage.get(r.to_e164) === false)) return false;
  return rows.every(r => r.body === rows[0].body);
}

export type Delivery =
  | { type: 'group'; groupKey: string; rows: OutboxRow[] }
  | { type: 'single'; row: OutboxRow }
  | { type: 'push'; row: OutboxRow };

/** Turns the sorted, due rows into sends. A group goes out at the position of its first row. */
export function planDeliveries(
  sorted: OutboxRow[],
  opts: { groupsSupported: boolean; iMessage: Map<string, boolean | undefined>; noGroup: Set<number> }
): Delivery[] {
  const byKey = new Map<string, OutboxRow[]>();
  for (const r of sorted) {
    if (!r.group_key || r.channel === 'push') continue;
    byKey.set(r.group_key, [...(byKey.get(r.group_key) ?? []), r]);
  }
  const out: Delivery[] = [];
  const done = new Set<number>();
  for (const r of sorted) {
    if (done.has(r.id)) continue;
    if (r.channel === 'push') {
      out.push({ type: 'push', row: r });
      continue;
    }
    const members = r.group_key ? byKey.get(r.group_key)! : [r];
    if (members.length > 1 && shouldSendAsGroup(members, opts)) {
      out.push({ type: 'group', groupKey: r.group_key, rows: members });
      for (const m of members) done.add(m.id);
    } else {
      out.push({ type: 'single', row: r });
    }
    done.add(r.id);
  }
  return out;
}

/** Which gateway channel a stored outbox channel maps to. WhatsApp is Stretch: sent as SMS. */
export function gatewayChannel(channel: string): TextChannel {
  if (channel === 'sms' || channel === 'whatsapp') return 'sms';
  if (channel === 'rcs') return 'rcs';
  return 'imessage';
}

// --- processor --------------------------------------------------------------------------

export interface OutboxStore {
  queuedOutbox(): Promise<OutboxRow[]>;
  outboxByStatus(status: string): Promise<OutboxRow[]>;
  outboxRow(id: number): Promise<OutboxRow | null>;
  markOutbox(id: number, status: string, channel?: string): Promise<void>;
  optOuts(): Promise<Set<string>>;
}

export type PushSender = Pick<AgentClient, 'push'>;

export interface Clock {
  now(): number;
}

export const systemClock: Clock = { now: () => Date.now() };

interface RetryState {
  failures: number;
  nextAt: number;
  fellBack: boolean;
}

export interface OutboxStats {
  lastPollAt: number;
  sent: number;
  failed: number;
  retries: number;
  groupSends: number;
  inFlight: number;
  pollErrors: number;
}

const SENT_MEMORY = 5_000;

export class OutboxProcessor {
  private readonly inFlight = new Set<number>();
  private readonly retry = new Map<number, RetryState>();
  /** Delivered but `sent` not yet recorded (e.g. SpacetimeDB blip): never resend these. */
  private readonly unmarked = new Map<number, string>();
  /** Recently delivered ids: a second line of duplicate protection. */
  private readonly sentIds = new Set<number>();
  private readonly noGroup = new Set<number>();
  private ticking = false;
  private timer: NodeJS.Timeout | null = null;
  readonly stats: OutboxStats = { lastPollAt: 0, sent: 0, failed: 0, retries: 0, groupSends: 0, inFlight: 0, pollErrors: 0 };

  constructor(
    private readonly store: OutboxStore,
    private readonly gateway: Gateway,
    private readonly pushSender: PushSender,
    private readonly opts: { appName: string; allowedLinkDomains?: string[]; clock?: Clock; pollMs?: number } = { appName: 'Kavach' }
  ) {}

  private now(): number {
    return (this.opts.clock ?? systemClock).now();
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.opts.pollMs ?? 500);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** At startup nothing is in flight, so `sending` rows were interrupted: requeue them (at-least-once). */
  async recoverInterrupted(): Promise<number> {
    const stuck = await this.store.outboxByStatus('sending');
    for (const r of stuck) await this.store.markOutbox(r.id, 'queued');
    if (stuck.length) log.warn('outbox.recovered_interrupted', { count: stuck.length });
    return stuck.length;
  }

  /** One poll. Never overlaps itself. Returns how many deliveries were attempted. */
  async tick(): Promise<number> {
    if (this.ticking) return 0;
    this.ticking = true;
    try {
      await this.flushUnmarked();
      const [rows, optOuts] = await Promise.all([this.store.queuedOutbox(), this.store.optOuts()]);
      this.stats.lastPollAt = this.now();
      const now = this.now();
      const due: OutboxRow[] = [];
      for (const r of rows) {
        if (this.inFlight.has(r.id)) continue;
        if (this.sentIds.has(r.id) || this.unmarked.has(r.id)) {
          // Already delivered once; just record it.
          await this.markSent(r.id, this.unmarked.get(r.id) ?? '');
          continue;
        }
        if ((this.retry.get(r.id)?.nextAt ?? 0) > now) continue;
        due.push(r);
      }
      if (!due.length) return 0;
      const sorted = sortQueue(due);
      const iMessage = await this.groupReachability(sorted);
      const plan = planDeliveries(sorted, { groupsSupported: this.gateway.supportsGroups(), iMessage, noGroup: this.noGroup });
      for (const d of plan) {
        if (d.type === 'group') await this.deliverGroup(d.groupKey, d.rows, optOuts);
        else await this.deliverOne(d.row, optOuts);
      }
      return plan.length;
    } catch (err) {
      this.stats.pollErrors++;
      log.error('outbox.poll_failed', { err });
      return 0;
    } finally {
      this.ticking = false;
    }
  }

  /** Live iMessage reachability, only for rows that could form a group. */
  private async groupReachability(rows: OutboxRow[]): Promise<Map<string, boolean | undefined>> {
    const counts = new Map<string, number>();
    for (const r of rows) if (r.group_key) counts.set(r.group_key, (counts.get(r.group_key) ?? 0) + 1);
    const out = new Map<string, boolean | undefined>();
    if (!this.gateway.supportsGroups()) return out;
    for (const r of rows) {
      if (!r.group_key || (counts.get(r.group_key) ?? 0) < 2 || r.channel !== 'imessage' || out.has(r.to_e164)) continue;
      out.set(r.to_e164, await this.gateway.isIMessage(r.to_e164));
    }
    return out;
  }

  /** Re-read the row right before sending: skip anything no longer queued. */
  private async stillQueued(id: number): Promise<OutboxRow | null> {
    const fresh = await this.store.outboxRow(id);
    return fresh && fresh.status === 'queued' ? fresh : null;
  }

  private blockedByOptOut(row: OutboxRow, optOuts: Set<string>): boolean {
    // The module lets `system` rows through (e.g. the opt-out confirmation); we match it.
    return row.channel !== 'push' && row.kind !== 'system' && optOuts.has(row.to_e164);
  }

  private async deliverOne(row: OutboxRow, optOuts: Set<string>): Promise<void> {
    this.inFlight.add(row.id);
    this.stats.inFlight = this.inFlight.size;
    const started = this.now();
    try {
      const fresh = await this.stillQueued(row.id);
      if (!fresh) return;
      if (this.blockedByOptOut(fresh, optOuts)) {
        await this.store.markOutbox(fresh.id, 'failed');
        this.stats.failed++;
        log.info('outbox.skipped_opt_out', { outbox_id: fresh.id, kind: fresh.kind });
        return;
      }
      await this.store.markOutbox(fresh.id, 'sending');
      let used: string;
      try {
        if (fresh.channel === 'push') {
          const res = await this.pushSender.push({
            to_e164: fresh.to_e164, title: this.opts.appName, body: fresh.body, category: fresh.kind,
          });
          if (!res.sent) throw new Error('push not sent');
          used = 'push';
        } else {
          const res = await this.gateway.sendToNumber(
            fresh.to_e164, styleBody(fresh.body, fresh.kind, this.opts.allowedLinkDomains), gatewayChannel(fresh.channel));
          used = res.channel;
        }
      } catch (err) {
        await this.onFailure(fresh, err);
        return;
      }
      this.unmarked.set(fresh.id, used === fresh.channel ? '' : used);
      await this.markSent(fresh.id, used === fresh.channel ? '' : used);
      log.info('outbox.sent', {
        outbox_id: fresh.id, kind: fresh.kind, priority: fresh.priority, channel: used, to: maskPhone(fresh.to_e164),
        incident_id: fresh.related_incident_id || undefined, latency_ms: this.now() - started,
        queued_ms: Math.max(0, Math.round(started - fresh.created_at / 1000)),
      });
    } finally {
      this.inFlight.delete(row.id);
      this.stats.inFlight = this.inFlight.size;
    }
  }

  private async deliverGroup(groupKey: string, rows: OutboxRow[], optOuts: Set<string>): Promise<void> {
    for (const r of rows) this.inFlight.add(r.id);
    const started = this.now();
    let members: OutboxRow[] = [];
    try {
      for (const r of rows) {
        const fresh = await this.stillQueued(r.id);
        if (!fresh) continue;
        if (this.blockedByOptOut(fresh, optOuts)) {
          await this.store.markOutbox(fresh.id, 'failed');
          this.stats.failed++;
          log.info('outbox.skipped_opt_out', { outbox_id: fresh.id, kind: fresh.kind });
          continue;
        }
        members.push(fresh);
      }
    } finally {
      for (const r of rows) this.inFlight.delete(r.id);
    }
    if (members.length < 2) {
      for (const m of members) await this.deliverOne(m, optOuts);
      return;
    }
    for (const m of members) this.inFlight.add(m.id);
    try {
      for (const m of members) await this.store.markOutbox(m.id, 'sending');
      try {
        await this.gateway.sendToGroup(members.map(m => m.to_e164), styleBody(members[0].body, members[0].kind, this.opts.allowedLinkDomains), groupKey);
      } catch (err) {
        // Next attempts go out individually.
        log.warn('outbox.group_failed', { group_key: groupKey, members: members.length, err });
        for (const m of members) {
          this.noGroup.add(m.id);
          await this.onFailure(m, err);
        }
        return;
      }
      this.stats.groupSends++;
      for (const m of members) {
        this.unmarked.set(m.id, '');
        await this.markSent(m.id, '');
      }
      log.info('outbox.sent_group', {
        group_key: groupKey, outbox_ids: members.map(m => m.id), kind: members[0].kind, members: members.length,
        incident_id: members[0].related_incident_id || undefined, latency_ms: this.now() - started,
      });
    } finally {
      for (const m of members) this.inFlight.delete(m.id);
    }
  }

  private async onFailure(row: OutboxRow, err: unknown): Promise<void> {
    const st = this.retry.get(row.id) ?? { failures: 0, nextAt: 0, fellBack: false };
    st.failures++;
    const step = nextStepAfterFailure(st.failures, row.channel, st.fellBack);
    const base = { outbox_id: row.id, kind: row.kind, channel: row.channel, failures: st.failures, err };
    try {
      if (step.action === 'retry') {
        st.nextAt = this.now() + step.delayMs;
        this.retry.set(row.id, st);
        this.stats.retries++;
        await this.store.markOutbox(row.id, 'queued');
        log.warn('outbox.retry_scheduled', { ...base, delay_ms: step.delayMs });
      } else if (step.action === 'fallback_sms') {
        st.fellBack = true;
        st.nextAt = this.now();
        this.retry.set(row.id, st);
        await this.store.markOutbox(row.id, 'queued', 'sms');
        log.warn('outbox.fallback_sms', base);
      } else {
        this.retry.delete(row.id);
        this.noGroup.delete(row.id);
        this.stats.failed++;
        await this.store.markOutbox(row.id, 'failed');
        log.error('outbox.failed', base);
      }
    } catch (markErr) {
      // Row stays `sending`; recoverInterrupted() requeues it on the next start.
      log.error('outbox.mark_failed', { outbox_id: row.id, err: markErr });
    }
  }

  private async markSent(id: number, channel: string): Promise<void> {
    try {
      await this.store.markOutbox(id, 'sent', channel);
      this.unmarked.delete(id);
      this.retry.delete(id);
      this.noGroup.delete(id);
      this.rememberSent(id);
      this.stats.sent++;
    } catch (err) {
      log.error('outbox.mark_sent_failed', { outbox_id: id, err });
    }
  }

  private async flushUnmarked(): Promise<void> {
    for (const [id, channel] of [...this.unmarked]) await this.markSent(id, channel);
  }

  private rememberSent(id: number): void {
    this.sentIds.add(id);
    if (this.sentIds.size > SENT_MEMORY) {
      const oldest = this.sentIds.values().next().value;
      if (oldest !== undefined) this.sentIds.delete(oldest);
    }
  }
}
