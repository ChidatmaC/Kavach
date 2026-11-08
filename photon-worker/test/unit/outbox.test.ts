import { describe, expect, it } from 'vitest';
import {
  BACKOFF_MS, OutboxProcessor, nextStepAfterFailure, planDeliveries, shouldSendAsGroup, sortQueue,
} from '../../src/outbox';
import { FakeGateway, ManualClock, MemoryStore, noPush, row } from '../helpers';

const noOpts = { groupsSupported: true, iMessage: new Map<string, boolean | undefined>(), noGroup: new Set<number>() };

describe('priority ordering', () => {
  it('puts urgent first, then oldest, then lowest id', () => {
    const rows = [
      row({ id: 1, priority: 'normal', created_at: 100 }),
      row({ id: 2, priority: 'urgent', created_at: 300 }),
      row({ id: 3, priority: 'normal', created_at: 50 }),
      row({ id: 4, priority: 'urgent', created_at: 200 }),
      row({ id: 5, priority: 'normal', created_at: 50 }),
    ];
    expect(sortQueue(rows).map(r => r.id)).toEqual([4, 2, 3, 5, 1]);
  });

  it('delivers in that order through the processor', async () => {
    const store = new MemoryStore([
      row({ id: 10, priority: 'normal', created_at: 1, to_e164: '+15555550110' }),
      row({ id: 11, priority: 'urgent', created_at: 5, to_e164: '+15555550111' }),
      row({ id: 12, priority: 'normal', created_at: 2, to_e164: '+15555550112' }),
    ]);
    const gw = new FakeGateway();
    await new OutboxProcessor(store, gw, noPush, { appName: 'Kavach' }).tick();
    expect(gw.sent.map(s => s.to[0])).toEqual(['+15555550111', '+15555550110', '+15555550112']);
    expect([...store.rows.values()].every(r => r.status === 'sent')).toBe(true);
  });
});

describe('retry and SMS fallback policy', () => {
  it('backs off 5/15/45 s, then switches iMessage to SMS once, then fails', () => {
    expect(nextStepAfterFailure(1, 'imessage', false)).toEqual({ action: 'retry', delayMs: 5_000 });
    expect(nextStepAfterFailure(2, 'imessage', false)).toEqual({ action: 'retry', delayMs: 15_000 });
    expect(nextStepAfterFailure(3, 'imessage', false)).toEqual({ action: 'retry', delayMs: 45_000 });
    expect(nextStepAfterFailure(4, 'imessage', false)).toEqual({ action: 'fallback_sms' });
    expect(nextStepAfterFailure(5, 'sms', true)).toEqual({ action: 'fail' });
  });
  it('fails SMS and push rows after 3 retries with no fallback', () => {
    expect(nextStepAfterFailure(4, 'sms', false)).toEqual({ action: 'fail' });
    expect(nextStepAfterFailure(4, 'push', false)).toEqual({ action: 'fail' });
  });
});

describe('processor retries with a fake clock', () => {
  it('waits out each backoff, falls back to SMS, then marks failed', async () => {
    const clock = new ManualClock();
    const store = new MemoryStore([row({ id: 1, channel: 'imessage', to_e164: '+15555550102' })]);
    const gw = new FakeGateway();
    gw.failWhen = () => true;
    const p = new OutboxProcessor(store, gw, noPush, { appName: 'Kavach', clock });

    await p.tick(); // attempt 1 fails
    expect(gw.attempts).toHaveLength(1);
    expect(store.rows.get(1)!.status).toBe('queued');

    for (const [i, delay] of BACKOFF_MS.entries()) {
      clock.advance(delay - 1);
      await p.tick();
      expect(gw.attempts).toHaveLength(i + 1); // not yet due
      clock.advance(1);
      await p.tick();
      expect(gw.attempts).toHaveLength(i + 2);
    }
    // 4 iMessage attempts done; the row was switched to SMS and is due immediately.
    expect(gw.attempts.map(a => a.channel)).toEqual(['imessage', 'imessage', 'imessage', 'imessage']);
    expect(store.rows.get(1)!.channel).toBe('sms');
    await p.tick();
    expect(gw.attempts.at(-1)!.channel).toBe('sms');
    expect(store.rows.get(1)!.status).toBe('failed');
    expect(store.rows.get(1)!.attempts).toBe(5);
    await p.tick();
    expect(gw.attempts).toHaveLength(5); // failed rows are left alone
  });

  it('recovers when a retry succeeds and records the channel used', async () => {
    const clock = new ManualClock();
    const store = new MemoryStore([row({ id: 2, channel: 'imessage', to_e164: '+15555550103' })]);
    const gw = new FakeGateway();
    gw.failWhen = r => r.channel === 'imessage';
    const p = new OutboxProcessor(store, gw, noPush, { appName: 'Kavach', clock });
    await p.tick();
    for (const d of BACKOFF_MS) {
      clock.advance(d);
      await p.tick();
    }
    await p.tick(); // SMS attempt succeeds
    expect(store.rows.get(2)!.status).toBe('sent');
    expect(store.rows.get(2)!.channel).toBe('sms');
    expect(gw.sent).toEqual([{ to: ['+15555550103'], body: 'message 2', channel: 'sms' }]);
  });
});

describe('group vs individual', () => {
  const fam = (id: number, to: string, channel = 'imessage', body = 'Joe asked for help during a call.') =>
    row({ id, to_e164: to, channel, body, kind: 'family_alert', group_key: 'family:1:7' });

  it('groups when every recipient is on iMessage with the same text', () => {
    expect(shouldSendAsGroup([fam(1, '+15555550102'), fam(2, '+15555550104')], noOpts)).toBe(true);
  });
  it('sends individually when any recipient is on SMS', () => {
    expect(shouldSendAsGroup([fam(1, '+15555550102'), fam(2, '+15555550103', 'sms')], noOpts)).toBe(false);
  });
  it('sends individually when live reachability says a recipient is not on iMessage', () => {
    const iMessage = new Map([['+15555550104', false]]);
    expect(shouldSendAsGroup([fam(1, '+15555550102'), fam(2, '+15555550104')], { ...noOpts, iMessage })).toBe(false);
  });
  it('sends individually when texts differ, the gateway has no groups, or a group already failed', () => {
    expect(shouldSendAsGroup([fam(1, '+15555550102'), fam(2, '+15555550104', 'imessage', 'other')], noOpts)).toBe(false);
    expect(shouldSendAsGroup([fam(1, '+15555550102'), fam(2, '+15555550104')], { ...noOpts, groupsSupported: false })).toBe(false);
    expect(shouldSendAsGroup([fam(1, '+15555550102'), fam(2, '+15555550104')], { ...noOpts, noGroup: new Set([2]) })).toBe(false);
    expect(shouldSendAsGroup([fam(1, '+15555550102')], noOpts)).toBe(false);
  });

  it('plans one group delivery at the position of its first row; push rows are separate', () => {
    const rows = sortQueue([
      row({ id: 1, priority: 'normal', created_at: 1 }),
      fam(2, '+15555550102'), fam(3, '+15555550104'),
      row({ id: 4, channel: 'push', created_at: 0 }),
    ].map(r => ({ ...r, created_at: r.created_at })));
    const plan = planDeliveries(rows, noOpts);
    expect(plan.map(d => d.type)).toEqual(['push', 'single', 'group']);
    const g = plan.find(d => d.type === 'group');
    expect(g && g.type === 'group' && g.rows.map(r => r.id)).toEqual([2, 3]);
  });

  it('processor: one group send for an all-iMessage family, individual sends otherwise', async () => {
    const store = new MemoryStore([fam(21, '+15555550102'), fam(22, '+15555550104')]);
    const gw = new FakeGateway();
    await new OutboxProcessor(store, gw, noPush, { appName: 'Kavach' }).tick();
    expect(gw.sent).toHaveLength(1);
    expect(gw.sent[0].group).toBe('family:1:7');
    expect(gw.sent[0].to.sort()).toEqual(['+15555550102', '+15555550104']);
    expect([...store.rows.values()].map(r => r.status)).toEqual(['sent', 'sent']);

    const store2 = new MemoryStore([fam(31, '+15555550102'), fam(32, '+15555550103', 'sms')]);
    const gw2 = new FakeGateway();
    await new OutboxProcessor(store2, gw2, noPush, { appName: 'Kavach' }).tick();
    expect(gw2.sent.map(s => [s.to[0], s.channel, s.group])).toEqual([
      ['+15555550102', 'imessage', undefined], ['+15555550103', 'sms', undefined],
    ]);
  });

  it('a failed group send retries as individual sends', async () => {
    const clock = new ManualClock();
    const store = new MemoryStore([fam(41, '+15555550102'), fam(42, '+15555550104')]);
    const gw = new FakeGateway();
    gw.failWhen = r => !!r.group;
    const p = new OutboxProcessor(store, gw, noPush, { appName: 'Kavach', clock });
    await p.tick();
    expect(gw.sent).toHaveLength(0);
    clock.advance(5_000);
    await p.tick();
    expect(gw.sent.map(s => s.to)).toEqual([['+15555550102'], ['+15555550104']]);
    expect([...store.rows.values()].every(r => r.status === 'sent')).toBe(true);
  });
});

describe('duplicate protection and opt-outs', () => {
  it('never sends a row twice, even if it shows up queued again', async () => {
    const store = new MemoryStore([row({ id: 51 })]);
    const gw = new FakeGateway();
    const p = new OutboxProcessor(store, gw, noPush, { appName: 'Kavach' });
    await p.tick();
    store.rows.get(51)!.status = 'queued'; // stale read / external requeue
    await p.tick();
    await p.tick();
    expect(gw.sent).toHaveLength(1);
  });

  it('skips rows whose status changed since the poll', async () => {
    const store = new MemoryStore([row({ id: 52 })]);
    const gw = new FakeGateway();
    const realGet = store.outboxRow.bind(store);
    store.outboxRow = async id => ({ ...(await realGet(id))!, status: 'sending' });
    await new OutboxProcessor(store, gw, noPush, { appName: 'Kavach' }).tick();
    expect(gw.sent).toHaveLength(0);
  });

  it('does not overlap ticks', async () => {
    const store = new MemoryStore([row({ id: 53 })]);
    const gw = new FakeGateway();
    const p = new OutboxProcessor(store, gw, noPush, { appName: 'Kavach' });
    await Promise.all([p.tick(), p.tick(), p.tick()]);
    expect(gw.sent).toHaveLength(1);
  });

  it('honors opt-outs except for system rows', async () => {
    const store = new MemoryStore([
      row({ id: 61, to_e164: '+15555550103', kind: 'family_alert' }),
      row({ id: 62, to_e164: '+15555550103', kind: 'system' }),
    ]);
    store.opted.add('+15555550103');
    const gw = new FakeGateway();
    await new OutboxProcessor(store, gw, noPush, { appName: 'Kavach' }).tick();
    expect(store.rows.get(61)!.status).toBe('failed');
    expect(store.rows.get(62)!.status).toBe('sent');
    expect(gw.sent).toHaveLength(1);
  });

  it('sends push rows to the agent service, not the gateway', async () => {
    const store = new MemoryStore([row({ id: 71, channel: 'push', kind: 'verification', body: 'Is this you?' })]);
    const gw = new FakeGateway();
    const pushes: unknown[] = [];
    await new OutboxProcessor(store, gw, { push: async a => { pushes.push(a); return { sent: true }; } }, { appName: 'Kavach' }).tick();
    expect(gw.sent).toHaveLength(0);
    expect(pushes).toEqual([{ to_e164: '+15555550101', title: 'Kavach', body: 'Is this you?', category: 'verification' }]);
    expect(store.rows.get(71)!.status).toBe('sent');
  });

  it('requeues rows left in sending by a crash', async () => {
    const store = new MemoryStore([row({ id: 81, status: 'sending' })]);
    const p = new OutboxProcessor(store, new FakeGateway(), noPush, { appName: 'Kavach' });
    expect(await p.recoverInterrupted()).toBe(1);
    expect(store.rows.get(81)!.status).toBe('queued');
  });
});
