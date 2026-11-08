// Photon Spectrum (spectrum-ts) iMessage gateway. The only code that talks to Photon (spec 9, D5).
//
// What the SDK gives us (spectrum-ts 12.15, read from its type definitions):
//  - Spectrum({ projectId, projectSecret, providers: [imessage.config()] }) connects to Spectrum Cloud.
//  - app.messages: AsyncIterable<[space, message]>; message.sender.service is iMessage | SMS | RCS.
//  - imessage(app).space.create(users, { phone }) creates a DM (1 user) or a group chat (2+ users).
//    Group creation needs a dedicated line; "shared" cloud mode throws UnsupportedError.
//  - imessage(app).space.get(chatGuid, { phone }) wraps a known chat guid (DMs are "any;-;<addr>").
//  - The underlying Advanced iMessage client has addresses.isIMessageAvailable(address).
//
// SMS/RCS: there is no "send as SMS" option in the SDK. A DM created with "any;-;" lets the line's
// Messages app pick the service (iMessage, else SMS/RCS if the host phone relays it). For our
// explicit iMessage -> SMS fallback we address the chat as "SMS;-;<addr>", Apple's SMS chat guid.
// Neither group creation nor SMS sending has been exercised against a real line (no credentials).
import { Spectrum, type Message, type Space } from 'spectrum-ts';
import { imessage } from 'spectrum-ts/providers/imessage';
import { log, maskPhone } from '../log';
import type { Gateway, InboundEvent, InboundHandlerFn, InboundImage, SendResult, TextChannel } from './types';

type App = Awaited<ReturnType<typeof Spectrum>>;
type IMessageInstance = ReturnType<typeof imessage<[ReturnType<typeof imessage.config>]>>;

interface AddressApi {
  addresses?: { isIMessageAvailable(address: string): Promise<boolean> };
}

export interface PhotonGatewayOptions {
  projectId: string;
  projectSecret: string;
  /** The managed iMessage line (PHOTON_AGENT_LINE), E.164. Empty = let the SDK pick. */
  line: string;
}

const AVAILABILITY_TTL_MS = 10 * 60_000;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

function serviceToChannel(service: unknown): TextChannel {
  if (service === 'SMS') return 'sms';
  if (service === 'RCS') return 'rcs';
  return 'imessage';
}

export class PhotonGateway implements Gateway {
  readonly name = 'photon';
  private app: App | null = null;
  private im: IMessageInstance | null = null;
  private running = false;
  private readonly spaces = new Map<string, Space>();
  private readonly availability = new Map<string, { value: boolean; at: number }>();

  constructor(private readonly opts: PhotonGatewayOptions) {
    if (!opts.projectId || !opts.projectSecret) {
      throw new Error('MESSAGING_GATEWAY=photon needs PHOTON_PROJECT_ID and PHOTON_API_KEY');
    }
  }

  async start(onMessage: InboundHandlerFn): Promise<void> {
    this.app = await Spectrum({
      projectId: this.opts.projectId,
      projectSecret: this.opts.projectSecret,
      providers: [imessage.config()],
      options: { logLevel: 'warn' },
      signal: AbortSignal.timeout(30_000),
    });
    this.im = imessage(this.app);
    this.running = true;
    void this.loop(onMessage);
    log.info('photon.started', { line: maskPhone(this.opts.line) });
  }

  private async loop(onMessage: InboundHandlerFn): Promise<void> {
    if (!this.app) return;
    try {
      for await (const [space, message] of this.app.messages) {
        if (!this.running) break;
        try {
          const ev = await this.toEvent(space, message);
          if (ev) await onMessage(ev);
        } catch (err) {
          log.error('photon.inbound_failed', { err });
        }
      }
    } catch (err) {
      log.error('photon.stream_ended', { err });
    }
  }

  private async toEvent(space: Space, message: Message): Promise<InboundEvent | null> {
    if (message.direction !== 'inbound' || !message.sender?.id) return null;
    const typed = imessage.is(message) ? imessage(message) : null;
    const sender = (typed?.sender ?? message.sender) as { id: string; address?: string; service?: string };
    const from = sender.address || sender.id;
    const isGroup = imessage.is(space) ? imessage(space).type === 'group' : false;
    let text = '';
    const images: InboundImage[] = [];
    const items = message.content.type === 'group' ? message.content.items.map(m => m.content) : [message.content];
    for (const c of items) {
      if (c.type === 'text') text = text ? `${text}\n${c.text}` : c.text;
      else if (c.type === 'attachment' && c.mimeType.startsWith('image/') && (c.size ?? 0) <= MAX_IMAGE_BYTES) {
        try {
          images.push({ mimeType: c.mimeType, base64: (await c.read()).toString('base64') });
        } catch (err) {
          log.warn('photon.attachment_read_failed', { err });
        }
      }
    }
    if (!text && images.length === 0) return null; // reactions, typing, polls: nothing to do
    return { id: message.id, from, channel: serviceToChannel(sender.service), text, images, isGroup, receivedAt: message.timestamp };
  }

  async stop(): Promise<void> {
    this.running = false;
    await this.app?.stop();
    this.app = null;
    this.im = null;
  }

  private params(): { phone?: string } {
    return this.opts.line ? { phone: this.opts.line } : {};
  }

  private requireIm(): IMessageInstance {
    if (!this.im) throw new Error('photon gateway not started');
    return this.im;
  }

  private async dmSpace(to: string, channel: TextChannel): Promise<Space> {
    const im = this.requireIm();
    const key = `${channel}:${to}`;
    const cached = this.spaces.get(key);
    if (cached) return cached;
    const space = channel === 'sms'
      ? await im.space.get(`SMS;-;${to}`, this.params())
      : await im.space.create(to, this.params());
    this.spaces.set(key, space);
    return space;
  }

  async sendToNumber(to: string, body: string, channel: TextChannel): Promise<SendResult> {
    const space = await this.dmSpace(to, channel);
    const sent = await space.send(body);
    let used: TextChannel = channel;
    if (channel !== 'sms') {
      const onIMessage = await this.isIMessage(to);
      if (onIMessage === false) used = 'sms';
    }
    return { channel: used, providerMessageId: sent?.id };
  }

  async sendToGroup(members: string[], body: string, groupKey: string): Promise<SendResult> {
    const im = this.requireIm();
    // Reuse one family thread per member set, not one per incident.
    const key = `group:${[...members].sort().join(',')}`;
    let space = this.spaces.get(key);
    if (!space) {
      space = await im.space.create(members, this.params());
      this.spaces.set(key, space);
      log.info('photon.group_created', { group_key: groupKey, members: members.length });
    }
    const sent = await space.send(body);
    return { channel: 'imessage', providerMessageId: sent?.id };
  }

  supportsGroups(): boolean {
    // Shared cloud mode cannot create groups; a dedicated line (PHOTON_AGENT_LINE) can.
    return !!this.opts.line;
  }

  async isIMessage(address: string): Promise<boolean | undefined> {
    const hit = this.availability.get(address);
    if (hit && Date.now() - hit.at < AVAILABILITY_TTL_MS) return hit.value;
    try {
      const runtime = this.app?.__internal.platforms.get('imessage');
      const clients = (runtime?.client ?? []) as Array<{ phone: string; client: AddressApi }>;
      const entry = clients.find(c => c.phone === this.opts.line) ?? clients[0];
      const api = entry?.client.addresses;
      if (!api) return undefined;
      const value = await api.isIMessageAvailable(address);
      this.availability.set(address, { value, at: Date.now() });
      return value;
    } catch (err) {
      log.warn('photon.availability_unknown', { to: maskPhone(address), err });
      return undefined;
    }
  }
}
