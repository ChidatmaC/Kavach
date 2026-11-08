// The messaging gateway seam. PhotonGateway (spectrum-ts iMessage) in production,
// ConsoleGateway for local development, FakeGateway in tests.

export type TextChannel = 'imessage' | 'sms' | 'rcs';

export interface InboundImage {
  mimeType: string;
  base64: string;
}

export interface InboundEvent {
  /** Provider message id; record_inbound_message dedupes on it. */
  id: string;
  /** Sender address, E.164. */
  from: string;
  /** The service the message arrived on. */
  channel: TextChannel;
  text: string;
  images: InboundImage[];
  /** True when it arrived in a group thread (everyone in the thread already saw it). */
  isGroup: boolean;
  receivedAt: Date;
}

export interface SendResult {
  /** The channel the provider actually used (may differ from the one requested). */
  channel: TextChannel;
  providerMessageId?: string;
}

export type InboundHandlerFn = (event: InboundEvent) => Promise<void>;

export interface Gateway {
  readonly name: string;
  /** Start receiving; the handler is awaited per message. */
  start(onMessage: InboundHandlerFn): Promise<void>;
  stop(): Promise<void>;
  /** Send to one number. `channel` is the requested service; SendResult.channel is what was used. */
  sendToNumber(to: string, body: string, channel: TextChannel): Promise<SendResult>;
  /** One group thread with every member. Only called when supportsGroups() and all members are on iMessage. */
  sendToGroup(members: string[], body: string, groupKey: string): Promise<SendResult>;
  supportsGroups(): boolean;
  /**
   * Live iMessage reachability when the provider can tell; undefined = unknown,
   * in which case the worker trusts the contact's stored channel.
   */
  isIMessage(address: string): Promise<boolean | undefined>;
}
