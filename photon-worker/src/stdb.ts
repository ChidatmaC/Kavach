// SpacetimeDB over HTTP (docs/CONTRACTS.md section 1), plus typed rows for the views this worker reads.
import { randomUUID } from 'node:crypto';

export class StdbError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
  }
}

export interface OutboxRow {
  id: number;
  to_e164: string;
  group_key: string;
  channel: string;
  kind: string;
  body: string;
  priority: string;
  related_incident_id: number;
  recipient_contact_id: number;
  status: string;
  attempts: number;
  created_at: number; // micros since epoch
}

export interface PersonRow {
  id: number;
  phone_e164: string;
  display_name: string;
  sharing_paused: boolean;
}

export interface ContactRow {
  id: number;
  person_id: number;
  name: string;
  phone_e164: string;
  relationship: string;
  channel: string;
  is_emergency_contact: boolean;
  consent_status: string;
}

export interface VerificationRow {
  id: number;
  person_id: number;
  contact_id: number;
  kind: string;
  status: string;
  created_at: number;
}

export interface IncidentRow {
  id: number;
  person_id: number;
  severity: string;
  status: string;
  family_ack_by: number;
  created_at: number;
}

export interface AlertRequestRow {
  id: number;
  person_id: number;
  incident_id: number;
  verification_id: number;
  kind: string; // help | alert | verify
  recipient_contact_ids: number[];
  status: string; // pending | acknowledged | unanswered
  acked_by_contact_id: number;
  created_at: number;
}

/** Timestamps arrive as [micros]; unwrap them, leave everything else alone. */
function unwrap(v: unknown): unknown {
  if (Array.isArray(v) && v.length === 1 && typeof v[0] === 'number') return v[0];
  return v;
}

/** Single-quote escape for the few literal values we put in SQL. */
export function sqlString(v: string): string {
  return `'${v.replace(/'/g, "''")}'`;
}

export class Stdb {
  constructor(
    private readonly uri: string,
    private readonly db: string,
    private readonly token: string,
    private readonly timeoutMs = 10_000
  ) {}

  async call(reducer: string, args: Record<string, unknown>): Promise<void> {
    const res = await fetch(`${this.uri}/v1/database/${this.db}/call/${reducer}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${this.token}`, 'content-type': 'application/json' },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!res.ok) throw new StdbError(res.status, `${reducer}: ${res.status} ${await res.text()}`);
  }

  async sql<T = Record<string, unknown>>(query: string): Promise<T[]> {
    const res = await fetch(`${this.uri}/v1/database/${this.db}/sql`, {
      method: 'POST',
      headers: { authorization: `Bearer ${this.token}` },
      body: query,
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!res.ok) throw new StdbError(res.status, `sql: ${res.status} ${await res.text()}`);
    const [result] = (await res.json()) as Array<{ schema: { elements: Array<{ name: { some: string } }> }; rows: unknown[][] }>;
    if (!result) return [];
    const names = result.schema.elements.map(e => e.name.some);
    return result.rows.map(r => Object.fromEntries(r.map((v, i) => [names[i], unwrap(v)])) as T);
  }

  // --- typed reads (SpacetimeDB SQL has no ORDER BY; callers sort) -----------------

  queuedOutbox(): Promise<OutboxRow[]> {
    return this.sql<OutboxRow>(`SELECT * FROM svc_outbox WHERE status = 'queued'`);
  }

  outboxByStatus(status: string): Promise<OutboxRow[]> {
    return this.sql<OutboxRow>(`SELECT * FROM svc_outbox WHERE status = ${sqlString(status)}`);
  }

  async outboxRow(id: number): Promise<OutboxRow | null> {
    const [row] = await this.sql<OutboxRow>(`SELECT * FROM svc_outbox WHERE id = ${Number(id)}`);
    return row ?? null;
  }

  outboxTo(e164: string): Promise<OutboxRow[]> {
    return this.sql<OutboxRow>(`SELECT * FROM svc_outbox WHERE to_e164 = ${sqlString(e164)}`);
  }

  async optOuts(): Promise<Set<string>> {
    const rows = await this.sql<{ phone_e164: string }>('SELECT * FROM svc_opt_out');
    return new Set(rows.map(r => r.phone_e164));
  }

  async personByPhone(e164: string): Promise<PersonRow | null> {
    const [p] = await this.sql<PersonRow>(`SELECT * FROM svc_person WHERE phone_e164 = ${sqlString(e164)}`);
    return p ?? null;
  }

  async personById(id: number): Promise<PersonRow | null> {
    const [p] = await this.sql<PersonRow>(`SELECT * FROM svc_person WHERE id = ${Number(id)}`);
    return p ?? null;
  }

  contactsByPhone(e164: string): Promise<ContactRow[]> {
    return this.sql<ContactRow>(`SELECT * FROM svc_contact WHERE phone_e164 = ${sqlString(e164)}`);
  }

  contactsOfPerson(personId: number): Promise<ContactRow[]> {
    return this.sql<ContactRow>(`SELECT * FROM svc_contact WHERE person_id = ${Number(personId)}`);
  }

  pendingVerifications(): Promise<VerificationRow[]> {
    return this.sql<VerificationRow>(`SELECT * FROM svc_verification WHERE status = 'pending'`);
  }

  /** Pending family requests. A one-element id list comes back unwrapped like a timestamp; re-wrap it. */
  async pendingAlertRequests(): Promise<AlertRequestRow[]> {
    const rows = await this.sql<AlertRequestRow>(`SELECT * FROM svc_alert_request WHERE status = 'pending'`);
    return rows.map(r => {
      const ids = r.recipient_contact_ids as unknown;
      return { ...r, recipient_contact_ids: (Array.isArray(ids) ? ids : [ids]).map(Number) };
    });
  }

  incidentsOfPerson(personId: number): Promise<IncidentRow[]> {
    return this.sql<IncidentRow>(`SELECT * FROM svc_incident WHERE person_id = ${Number(personId)}`);
  }

  async inboundSeen(photonMessageId: string): Promise<boolean> {
    const rows = await this.sql(`SELECT * FROM svc_inbound_message WHERE photon_message_id = ${sqlString(photonMessageId)}`);
    return rows.length > 0;
  }

  // --- reducers ---------------------------------------------------------------------

  markOutbox(outboxId: number, status: string, channel = ''): Promise<void> {
    return this.call('mark_outbox_status', { outbox_id: outboxId, status, channel });
  }

  enqueue(a: {
    to_e164: string; channel: string; kind: string; body: string; priority?: string;
    related_incident_id?: number; recipient_contact_id?: number; group_key?: string;
  }): Promise<void> {
    return this.call('enqueue_outbox', {
      to_e164: a.to_e164, channel: a.channel, kind: a.kind, body: a.body, priority: a.priority ?? 'normal',
      related_incident_id: a.related_incident_id ?? 0, recipient_contact_id: a.recipient_contact_id ?? 0,
      group_key: a.group_key ?? '',
    });
  }

  /** open_incident returns nothing; read the row back by request_key. */
  async openIncident(personId: number, entryPoint: string, callerE164 = ''): Promise<number> {
    const key = randomUUID();
    await this.call('open_incident', { request_key: key, person_id: personId, entry_point: entryPoint, caller_e164: callerE164 });
    const [row] = await this.sql<{ id: number }>(`SELECT * FROM svc_incident WHERE request_key = ${sqlString(key)}`);
    if (!row) throw new Error('open_incident: row not found after insert');
    return row.id;
  }
}
