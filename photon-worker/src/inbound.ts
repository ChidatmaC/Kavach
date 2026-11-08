// Inbound handling (spec 3 "Inbound text flow", spec 9 "Inbound handling" and text commands).
//
// 1. record_inbound_message (skip if this provider message id was already seen)
// 2. match the sender to a person, or to a family contact
// 3. local commands first (commands.ts), then family replies (acknowledge pending help/alert requests,
//    relay free text to the rest of the family), then POST /run/router
// Every reply leaves through enqueue_outbox (D6); this module never sends directly.
import type { AgentClient, RouterResult } from './agent';
import { CLARIFY_MARKER, forwardWrapper, isClarifyAnswer, isShortAck, parseCommand, sameName, type Command } from './commands';
import type { InboundEvent } from './gateway/types';
import { log, maskPhone } from './log';
import type { ContactRow, IncidentRow, OutboxRow, PersonRow, Stdb, VerificationRow } from './stdb';

export type InboundStore = Pick<Stdb,
  | 'call' | 'inboundSeen' | 'personByPhone' | 'personById' | 'contactsByPhone' | 'contactsOfPerson'
  | 'pendingVerifications' | 'pendingAlertRequests' | 'incidentsOfPerson' | 'outboxTo' | 'optOuts' | 'enqueue'
  | 'openIncident'>;

export type InboundAgent = Pick<AgentClient, 'router' | 'scamCheck' | 'advise' | 'command' | 'verifyRelative' | 'interview'>;

export interface InboundOptions {
  appName: string;
  familyReplyWindowMs: number;
  clock?: { now(): number };
}

export type InboundOutcome =
  | 'duplicate' | 'empty' | 'ignored_opted_out'
  | `command:${Command['type']}` | 'relay' | 'family_ack' | 'image_check' | `routed:${string}` | 'router_failed';

const E164 = /^\+[1-9]\d{6,14}$/;
const FAMILY_KINDS = new Set(['family_alert', 'relay', 'verification', 'checkin']);
const ACTIVE_SEVERITY = new Set(['high', 'critical']);
const ACK_KINDS = new Set(['help', 'alert']);
const SEEN_MEMORY = 5_000;
const CLARIFY_WINDOW_MS = 10 * 60_000; // the router remembers an ambiguous text for 10 minutes

export const SCAM_CHECK_FALLBACK = "I couldn't check this right now. Don't reply or tap any links, and ask someone you trust.";

export function helpText(app: string): string {
  return `${app}: Forward me any text, link or screenshot that worries you and I'll tell you if it looks like a scam. ` +
    `Start a forwarded text with "Forwarded message:" so I know it's something you received, or just ask me a question. ` +
    `Text "verify" and a name (like "verify Tommy") to check it's really them. ` +
    `Text "pause" or "resume" for family alerts, or "stop" to opt out.`;
}

export class InboundProcessor {
  private readonly seen = new Set<string>();

  constructor(
    private readonly db: InboundStore,
    private readonly agent: InboundAgent,
    private readonly opts: InboundOptions
  ) {}

  private now(): number {
    return (this.opts.clock ?? { now: () => Date.now() }).now();
  }

  async handle(ev: InboundEvent): Promise<InboundOutcome> {
    const started = this.now();
    const outcome = await this.process(ev).catch(err => {
      log.error('inbound.failed', { photon_message_id: ev.id, from: maskPhone(ev.from), err });
      throw err;
    });
    log.info('inbound.handled', {
      photon_message_id: ev.id, from: maskPhone(ev.from), channel: ev.channel, outcome,
      images: ev.images.length || undefined, group: ev.isGroup || undefined, latency_ms: this.now() - started,
    });
    return outcome;
  }

  private async process(ev: InboundEvent): Promise<InboundOutcome> {
    if (!E164.test(ev.from)) throw new Error('sender is not an E.164 number');
    // Duplicate protection: in-process first (concurrent redeliveries), then the database.
    if (this.seen.has(ev.id)) return 'duplicate';
    this.remember(ev.id);
    if (await this.db.inboundSeen(ev.id)) return 'duplicate';
    await this.db.call('record_inbound_message', {
      photon_message_id: ev.id, from_e164: ev.from, channel: ev.channel,
      body: ev.text || (ev.images.length ? '[image]' : ''),
    });
    if (!ev.text.trim() && ev.images.length === 0) return 'empty';

    const [person, contacts, optOuts] = await Promise.all([
      this.db.personByPhone(ev.from), this.db.contactsByPhone(ev.from), this.db.optOuts(),
    ]);
    // A forward wrapper ("Forwarded message:", "Fwd:", "Check this"...) is someone else's text: never a local
    // command or a family "seen it" reply, whatever words are inside it. The router scam-checks it.
    const wrapped = ev.images.length ? null : forwardWrapper(ev.text);
    const cmd = ev.images.length || wrapped ? null : parseCommand(ev.text);

    if (optOuts.has(ev.from) && cmd?.type !== 'start' && cmd?.type !== 'stop') return 'ignored_opted_out';

    if (cmd) {
      const handled = await this.command(cmd, ev, person, contacts);
      if (handled) return `command:${cmd.type}`;
    }

    if (ev.images.length) {
      await this.acknowledge(ev, 'image');
      return this.imageCheck(ev, await this.ensurePerson(ev.from, person));
    }

    // "1" / "2" answering our "received, or your question?" prompt belongs to the router too.
    const clarifying = !wrapped && isClarifyAnswer(ev.text) && (await this.askedToClarify(ev));
    if (!wrapped && !clarifying) {
      const family = await this.familyReply(ev, contacts, cmd);
      if (family) return family;
    }

    // A bare marker ("Fwd:") gets no reply: the forwarded text is on its way.
    if (!wrapped?.bare) await this.acknowledge(ev, 'text');
    return this.route(ev, await this.ensurePerson(ev.from, person));
  }

  /**
   * Instant acknowledgement before the agent runs (a full answer takes a few seconds). Urgent, so the
   * outbox sends it on its next poll, ahead of the answer. Commands skip this: they reply at once.
   */
  private async acknowledge(ev: InboundEvent, what: 'text' | 'image'): Promise<void> {
    const body = what === 'image'
      ? `${this.opts.appName}: Got your screenshot. Reading it now, one moment…`
      : `${this.opts.appName}: Got it. Checking this now, one moment…`;
    try {
      await this.reply(ev, body, 'system', 'urgent');
    } catch (err) {
      log.warn('inbound.ack_failed', { from: maskPhone(ev.from), err });
    }
  }

  /** Our latest message to this number, within 10 minutes, was the router's clarifying question. */
  private async askedToClarify(ev: InboundEvent): Promise<boolean> {
    try {
      const since = (this.now() - CLARIFY_WINDOW_MS) * 1000; // micros
      const latest = (await this.db.outboxTo(ev.from))
        .filter((r: OutboxRow) => r.created_at >= since && r.kind !== 'push')
        .sort((a, b) => b.created_at - a.created_at)
        .find(r => !String(r.body).includes('Checking this now'));
      return !!latest && String(latest.body).includes(CLARIFY_MARKER);
    } catch {
      return false;
    }
  }

  private remember(id: string): void {
    this.seen.add(id);
    if (this.seen.size > SEEN_MEMORY) {
      const oldest = this.seen.values().next().value;
      if (oldest !== undefined) this.seen.delete(oldest);
    }
  }

  private reply(ev: InboundEvent, body: string, kind = 'reply', priority = 'normal'): Promise<void> {
    return this.db.enqueue({ to_e164: ev.from, channel: ev.channel, kind, body: body.slice(0, 600), priority });
  }

  private async ensurePerson(phone: string, existing: PersonRow | null): Promise<PersonRow> {
    if (existing) return existing;
    await this.db.call('ensure_person', { phone, name: '' });
    const p = await this.db.personByPhone(phone);
    if (!p) throw new Error('ensure_person did not create a person');
    return p;
  }

  // --- commands ---------------------------------------------------------------------------

  /** Returns false when the command doesn't apply to this sender, so the text goes on to the router. */
  private async command(cmd: Command, ev: InboundEvent, person: PersonRow | null, contacts: ContactRow[]): Promise<boolean> {
    const app = this.opts.appName;
    switch (cmd.type) {
      case 'stop':
        await this.db.call('opt_out_number', { phone: ev.from, opt_out: true });
        // One confirmation; `system` is the only kind the module still delivers after an opt-out.
        await this.reply(ev, `${app}: You're unsubscribed and won't get more messages from us. Text START to turn them back on.`, 'system');
        return true;
      case 'start':
        await this.db.call('opt_out_number', { phone: ev.from, opt_out: false });
        await this.reply(ev, `${app}: Messages are back on. Text HELP to see what I can do.`);
        return true;
      case 'help':
        await this.reply(ev, helpText(app));
        return true;
      case 'join':
        return this.join(cmd.name, ev, contacts);
      case 'confirm':
      case 'deny':
        return this.answerVerification(cmd.type === 'confirm' ? 'confirmed' : 'denied', ev, contacts);
      case 'ack':
        return this.familyAck(ev, contacts);
      case 'pause':
      case 'resume': {
        if (!person) return false;
        const paused = cmd.type === 'pause';
        await this.db.call('set_sharing_paused', { person_id: person.id, paused });
        await this.reply(ev, paused
          ? `${app}: Family alerts are paused. Text "resume" to turn them back on.`
          : `${app}: Family alerts are back on.`);
        return true;
      }
      case 'verify':
        if (!person) return false;
        await this.verify(person, cmd.name, ev);
        return true;
    }
  }

  private async join(name: string, ev: InboundEvent, contacts: ContactRow[]): Promise<boolean> {
    const app = this.opts.appName;
    if (!contacts.length) {
      await this.reply(ev, `${app}: I couldn't find an invite for this number. Ask them to add you as a family contact in the app.`);
      return true;
    }
    const candidates: Array<{ contact: ContactRow; person: PersonRow | null }> = [];
    for (const c of contacts) candidates.push({ contact: c, person: await this.db.personById(c.person_id) });
    const named = candidates.filter(x => x.person && sameName(x.person.display_name, name));
    const pick = named[0] ?? (candidates.length === 1 ? candidates[0] : undefined);
    if (!pick) {
      await this.reply(ev, `${app}: I couldn't find an invite from ${name}. Check the name in their invite and try "join" again.`);
      return true;
    }
    await this.db.call('set_contact_consent', { contact_id: pick.contact.id, consent_status: 'accepted' });
    const who = pick.person?.display_name ?? name;
    await this.reply(ev, `${app}: Thanks, you've joined ${who}'s family circle. You'll hear from us only if a scammer reaches them. Text "stop" any time to leave.`);
    return true;
  }

  private async answerVerification(result: 'confirmed' | 'denied', ev: InboundEvent, contacts: ContactRow[]): Promise<boolean> {
    if (!contacts.length) return false;
    const ids = new Set(contacts.map(c => c.id));
    const pending = (await this.db.pendingVerifications())
      .filter((v: VerificationRow) => ids.has(v.contact_id))
      .sort((a, b) => b.created_at - a.created_at);
    const v = pending[0];
    if (!v) return false;
    await this.db.call('resolve_verification', { verification_id: v.id, result });
    const person = await this.db.personById(v.person_id);
    const name = person?.display_name ?? 'them';
    await this.reply(ev, result === 'confirmed'
      ? `${this.opts.appName}: Thanks for confirming. We've let ${name} know it's really you.`
      : `${this.opts.appName}: Thank you. We've told ${name} it's a scam and let the family know.`);
    log.info('inbound.verification_resolved', { verification_id: v.id, result });
    return true;
  }

  private async familyAck(ev: InboundEvent, contacts: ContactRow[]): Promise<boolean> {
    let best: { incident: IncidentRow; contact: ContactRow } | null = null;
    for (const c of contacts) {
      for (const inc of await this.db.incidentsOfPerson(c.person_id)) {
        if (!ACTIVE_SEVERITY.has(inc.severity) || inc.status === 'resolved') continue;
        if (!best || inc.created_at > best.incident.created_at) best = { incident: inc, contact: c };
      }
    }
    if (!best) return false;
    await this.db.call('family_ack', { incident_id: best.incident.id, contact_id: best.contact.id });
    const person = await this.db.personById(best.incident.person_id);
    await this.reply(ev, best.incident.family_ack_by && best.incident.family_ack_by !== best.contact.id
      ? `${this.opts.appName}: Thanks. Someone else in the family is already calling ${person?.display_name ?? 'them'}, but another call won't hurt.`
      : `${this.opts.appName}: Thank you. We've told the rest of the family you're calling ${person?.display_name ?? 'them'}.`);
    return true;
  }

  private async verify(person: PersonRow, relativeName: string, ev: InboundEvent): Promise<void> {
    try {
      await this.agent.verifyRelative({ person_id: person.id, relative_name: relativeName });
    } catch (err) {
      log.warn('inbound.verify_relative_failed', { person_id: person.id, err });
      await this.reply(ev, `${this.opts.appName}: I couldn't start that check right now. Call ${relativeName} on the number you already have for them, not one from a message.`);
    }
  }

  // --- family replies (CONTRACTS section 7) and thread relay (spec 9 outbound step 6) ----------

  /**
   * Any reply from an accepted family member counts as "I saw it" for their pending help/alert
   * requests. Short acknowledgements ("ok", "got it", a thumbs up) stop there: no relay, no scam
   * check. Free text is also relayed to the rest of the family. Returns null to keep routing.
   */
  private async familyReply(ev: InboundEvent, contacts: ContactRow[], cmd: Command | null): Promise<InboundOutcome | null> {
    if (!contacts.length) return null;
    if (ev.isGroup) {
      await this.acknowledgeFamily(contacts);
      return 'relay'; // group thread: everyone already saw it
    }
    // "on it" with no open High/Critical incident fell through from the ack command: still a "seen it".
    const short = isShortAck(ev.text) || cmd?.type === 'ack';
    if (short) {
      const names = await this.acknowledgeFamily(contacts);
      if (!names.length && !(await this.recentFamilyThread(ev))) return null;
      await this.reply(ev, names.length
        ? `${this.opts.appName}: Thanks, we've let ${joinNames(names)} know you saw it.`
        : `${this.opts.appName}: Thanks, got it.`);
      return 'family_ack';
    }
    const names = await this.acknowledgeFamily(contacts);
    if (await this.relayFamilyReply(ev, contacts)) return 'relay';
    if (!names.length) return null;
    await this.reply(ev, `${this.opts.appName}: Thanks, we've let ${joinNames(names)} know you saw it.`);
    return 'family_ack';
  }

  /**
   * acknowledge_family_alert for every accepted contact row of this number that a pending help/alert
   * request lists. Returns the names of the people told. Never throws: a failed ack must not lose the reply.
   */
  private async acknowledgeFamily(contacts: ContactRow[]): Promise<string[]> {
    const accepted = contacts.filter(c => c.consent_status === 'accepted');
    if (!accepted.length) return [];
    const names: string[] = [];
    try {
      const pending = (await this.db.pendingAlertRequests()).filter(r => ACK_KINDS.has(r.kind));
      for (const c of accepted) {
        if (!pending.some(r => r.person_id === c.person_id && r.recipient_contact_ids.includes(c.id))) continue;
        await this.db.call('acknowledge_family_alert', { contact_id: c.id });
        const person = await this.db.personById(c.person_id);
        if (person?.display_name && !names.includes(person.display_name)) names.push(person.display_name);
        log.info('inbound.family_acknowledged', { person_id: c.person_id, contact_id: c.id });
      }
    } catch (err) {
      log.warn('inbound.family_ack_failed', { err });
    }
    return names;
  }

  private async recentFamilyThread(ev: InboundEvent): Promise<boolean> {
    const since = (this.now() - this.opts.familyReplyWindowMs) * 1000; // micros
    return (await this.db.outboxTo(ev.from)).some((r: OutboxRow) => FAMILY_KINDS.has(r.kind) && r.created_at >= since);
  }

  /**
   * A contact who we texted about their person recently is replying in the family thread.
   * Without a group thread, pass it on to the other accepted members, prefixed with their name.
   */
  private async relayFamilyReply(ev: InboundEvent, contacts: ContactRow[]): Promise<boolean> {
    const accepted = contacts.filter(c => c.consent_status === 'accepted');
    if (!accepted.length) return false;
    const since = (this.now() - this.opts.familyReplyWindowMs) * 1000; // micros
    const recent = (await this.db.outboxTo(ev.from))
      .filter((r: OutboxRow) => FAMILY_KINDS.has(r.kind) && r.created_at >= since)
      .sort((a, b) => b.created_at - a.created_at);
    if (!recent.length) return false;
    const latest = recent[0];
    const sender = accepted.find(c => c.id === latest.recipient_contact_id) ?? accepted[0];
    const person = await this.db.personById(sender.person_id);
    if (!person || person.sharing_paused) return false;
    const others = (await this.db.contactsOfPerson(person.id))
      .filter(c => c.id !== sender.id && c.consent_status === 'accepted' && c.phone_e164 !== ev.from);
    const body = `${sender.name}: ${ev.text.trim()}`.slice(0, 600);
    for (const o of others) {
      await this.db.enqueue({
        to_e164: o.phone_e164, channel: o.channel, kind: 'relay', body, priority: 'normal',
        related_incident_id: latest.related_incident_id, recipient_contact_id: o.id,
      });
    }
    log.info('inbound.relayed', { person_id: person.id, contact_id: sender.id, recipients: others.length });
    return true;
  }

  // --- agent workflows -----------------------------------------------------------------------

  private async imageCheck(ev: InboundEvent, person: PersonRow): Promise<InboundOutcome> {
    try {
      await this.agent.scamCheck({
        person_id: person.id, text: ev.text, source: 'screenshot', reply_to_e164: ev.from, reply_channel: ev.channel,
        image_base64: ev.images[0].base64,
      });
    } catch (err) {
      log.warn('inbound.scam_check_failed', { person_id: person.id, err });
      await this.reply(ev, SCAM_CHECK_FALLBACK);
    }
    return 'image_check';
  }

  private async scamCheck(ev: InboundEvent, person: PersonRow, args: Record<string, unknown> = {}): Promise<void> {
    try {
      await this.agent.scamCheck({
        person_id: person.id,
        text: typeof args.text === 'string' && args.text ? args.text : ev.text,
        sender_e164: typeof args.sender_e164 === 'string' && E164.test(args.sender_e164) ? args.sender_e164 : undefined,
        source: 'imessage', reply_to_e164: ev.from, reply_channel: ev.channel,
        ...(args.teach_wrapper === true ? { teach_wrapper: true } : {}),
      });
    } catch (err) {
      log.warn('inbound.scam_check_failed', { person_id: person.id, err });
      await this.reply(ev, SCAM_CHECK_FALLBACK);
    }
  }

  private async route(ev: InboundEvent, person: PersonRow): Promise<InboundOutcome> {
    let r: RouterResult;
    try {
      r = await this.agent.router({ text: ev.text, from_e164: ev.from, channel: ev.channel, person_id: person.id });
    } catch (err) {
      // Check the text rather than go silent (a wrapped forward: only the forwarded part).
      log.warn('inbound.router_failed', { person_id: person.id, err });
      const wrapped = forwardWrapper(ev.text);
      if (wrapped?.bare) return 'router_failed';
      await this.scamCheck(ev, person, wrapped ? { text: wrapped.inner } : {});
      return 'router_failed';
    }
    const args = r.args ?? {};
    const app = this.opts.appName;
    switch (r.intent) {
      case 'scam_check':
        await this.scamCheck(ev, person, args);
        break;
      case 'advise':
        try {
          await this.agent.advise({
            person_id: person.id, text: typeof args.text === 'string' && args.text ? args.text : ev.text,
            reply_to_e164: ev.from, reply_channel: ev.channel,
          });
        } catch (err) {
          log.warn('inbound.advise_failed', { person_id: person.id, err });
          await this.reply(ev, `${app}: I couldn't answer that right now. Until we can talk it through, don't send money, gift cards or codes, and check with someone you trust.`);
        }
        break;
      case 'command':
        try {
          // args is the /run/command body; args.text is the remembered text after a "2" answer.
          const body = args as { text?: unknown; args?: unknown };
          await this.agent.command({
            person_id: person.id, text: typeof body.text === 'string' && body.text ? body.text : ev.text,
            reply_to_e164: ev.from, reply_channel: ev.channel,
            args: body.args && typeof body.args === 'object' ? body.args as Record<string, unknown> : args,
          });
        } catch (err) {
          log.warn('inbound.command_failed', { person_id: person.id, err });
          await this.reply(ev, `${app}: I couldn't do that right now. Please try again in a minute, or text "help" to see what I can do.`);
        }
        break;
      case 'verify_relative': {
        const name = typeof args.relative_name === 'string' ? args.relative_name : '';
        if (name) await this.verify(person, name, ev);
        else await this.reply(ev, `${app}: Who should I check with? Text "verify" and their name, like "verify Tommy".`);
        break;
      }
      case 'interview':
        await this.interview(ev, person, args);
        break;
      case 'clarify':
        // Ambiguous text: one short question ("received, or your question?"). Empty after a bare "Fwd:".
        if (typeof args.reply === 'string' && args.reply) await this.reply(ev, args.reply);
        break;
      case 'pause':
      case 'resume':
      case 'stop':
      case 'help':
        await this.command({ type: r.intent }, ev, person, []);
        break;
      default:
        await this.reply(ev, `${app} only helps with scams and staying safe. Forward me a message or link you're unsure about, or text "help".`);
    }
    return `routed:${r.intent}`;
  }

  private async interview(ev: InboundEvent, person: PersonRow, args: Record<string, unknown>): Promise<void> {
    try {
      let incidentId = typeof args.incident_id === 'number' ? args.incident_id : 0;
      if (!incidentId) {
        const open = (await this.db.incidentsOfPerson(person.id))
          .filter(i => i.status !== 'resolved')
          .sort((a, b) => b.created_at - a.created_at)[0];
        incidentId = open?.id ?? (await this.db.openIncident(person.id, 'imessage'));
      }
      // D6: in text mode the interview workflow queues its own reply through the outbox.
      const utterance = typeof args.utterance === 'string' && args.utterance ? args.utterance : ev.text;
      await this.agent.interview({ incident_id: incidentId, mode: 'text', utterance });
    } catch (err) {
      log.warn('inbound.interview_failed', { person_id: person.id, err });
      await this.reply(ev, `${this.opts.appName}: I couldn't continue right now. If someone is pressuring you, hang up and call a family member.`);
    }
  }
}

function joinNames(names: string[]): string {
  return names.length <= 1 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}
