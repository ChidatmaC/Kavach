// Kavach SpacetimeDB schema (spec section 5, plus D14/D15 report_evidence).
//
// Conventions shared with every client (see docs/CONTRACTS.md):
// - Column and reducer argument names are snake_case on the wire.
// - "No value" is a sentinel, not an option: 0 for ids, "" for strings,
//   Timestamp(0) for timestamps. This keeps HTTP JSON simple for Python and Swift.
// - Enum-like fields are strings validated by reducers.
import { CaseConversionPolicy, schema, table, t } from 'spacetimedb/server';

// --- identities -------------------------------------------------------------

/** Service identities (agents, photon, voice, admin). Private. */
export const serviceAccount = table(
  { name: 'service_account' },
  {
    identity: t.identity().primaryKey(),
    role: t.string(), // agents | photon | voice | admin
  }
);

// --- people -----------------------------------------------------------------

export const person = table(
  { name: 'person' },
  {
    id: t.u64().primaryKey().autoInc(),
    owner_hex: t.string().index('btree'), // app identity hex, "" until the app registers
    phone_e164: t.string().unique(),
    display_name: t.string(),
    accessibility_mode: t.bool(),
    sharing_paused: t.bool(),
    critical_overrides_pause: t.bool(),
    practice_consent: t.bool(),
    apns_token: t.string(),
    family_code_word: t.string(),
    tz_offset_minutes: t.i32(),
    recovery_watch_until: t.timestamp(),
    campaign_watch_until: t.timestamp(),
    watch_campaign_id: t.u64(),
    watch_caller_e164: t.string(),
    created_at: t.timestamp(),
  }
);

export const contact = table(
  { name: 'contact' },
  {
    id: t.u64().primaryKey().autoInc(),
    person_id: t.u64().index('btree'),
    name: t.string(),
    phone_e164: t.string().index('btree'),
    relationship: t.string(),
    channel: t.string(), // imessage | sms | rcs | whatsapp
    is_emergency_contact: t.bool(),
    is_app_user: t.bool(),
    linked_person_id: t.u64(),
    consent_status: t.string(), // invited | accepted | declined
  }
);

/** Numbers that sent "stop". Honored on every channel. */
export const optOut = table(
  { name: 'opt_out' },
  {
    phone_e164: t.string().primaryKey(),
    created_at: t.timestamp(),
  }
);

// --- messages and checks ------------------------------------------------------

export const inboundMessage = table(
  { name: 'inbound_message' },
  {
    id: t.u64().primaryKey().autoInc(),
    from_e164: t.string().index('btree'),
    person_id: t.u64(),
    channel: t.string(),
    body: t.string(),
    photon_message_id: t.string().unique(),
    received_at: t.timestamp(),
  }
);

export const messageCheck = table(
  { name: 'message_check' },
  {
    id: t.u64().primaryKey().autoInc(),
    request_key: t.string().unique(),
    person_id: t.u64().index('btree'),
    source: t.string(), // imessage | share | app_paste | screenshot | call
    content_redacted: t.string(),
    verdict: t.string(), // safe | suspicious | likely_scam
    model_verdict: t.string(), // what the model said before the community floor
    reason: t.string(),
    campaign_id: t.u64(),
    evidence_count: t.u32(),
    created_at: t.timestamp(),
  }
);

// --- incidents ----------------------------------------------------------------

export const incident = table(
  { name: 'incident' },
  {
    id: t.u64().primaryKey().autoInc(),
    request_key: t.string().unique(),
    person_id: t.u64().index('btree'),
    entry_point: t.string(), // report_swipe | companion | hotline | imessage | app
    caller_e164: t.string(),
    claimed_identity: t.string(),
    answers_json: t.string(),
    tactics: t.array(t.string()),
    shared_items: t.array(t.string()),
    severity: t.string(), // "" | low | medium | high | critical
    status: t.string(), // open | in_progress | resolved
    family_ack_by: t.u64(),
    campaign_id: t.u64(),
    summary_redacted: t.string(),
    created_at: t.timestamp(),
    resolved_at: t.timestamp(),
  }
);

export const recoveryStep = table(
  { name: 'recovery_step' },
  {
    id: t.u64().primaryKey().autoInc(),
    incident_id: t.u64().index('btree'),
    step_key: t.string(),
    priority: t.string(), // now | today | this_week
    sort_order: t.u32(),
    done: t.bool(),
  }
);

// --- community intelligence (D14, D15: service-only) --------------------------

export const communityReport = table(
  {
    name: 'community_report',
    indexes: [{ accessor: 'by_kind_value', algorithm: 'btree', columns: ['kind', 'value'] }],
  },
  {
    id: t.u64().primaryKey().autoInc(),
    kind: t.string(), // number | link | phrase
    value: t.string(),
    campaign_id: t.u64(),
    reporter_count: t.u32(),
    label_visible: t.bool(),
    last_reported_at: t.timestamp(),
  }
);

export const reportVote = table(
  {
    name: 'report_vote',
    indexes: [{ accessor: 'by_report_voter', algorithm: 'btree', columns: ['report_id', 'voter_key'] }],
  },
  {
    id: t.u64().primaryKey().autoInc(),
    report_id: t.u64(),
    voter_key: t.string(), // "p:<person_id>" or "e:<e164>" for unregistered hotline callers
  }
);

export const reportEvidence = table(
  { name: 'report_evidence' },
  {
    id: t.u64().primaryKey().autoInc(),
    report_id: t.u64(),
    source: t.string(), // message | call | hotline | seed
    channel: t.string(),
    sender_e164: t.string().index('btree'),
    links: t.array(t.string()),
    claimed_identity: t.string(),
    tactics: t.array(t.string()),
    text_redacted: t.string(),
    verdict: t.string(), // suspicious | likely_scam
    campaign_id: t.u64(),
    created_at: t.timestamp(),
    incident_id: t.u64().default(0n), // set for incident-derived rows; one row per incident
  }
);

/** Public: campaign summaries power the "This week" section. */
export const campaign = table(
  { name: 'campaign', public: true },
  {
    id: t.u64().primaryKey().autoInc(),
    slug: t.string().unique(),
    title: t.string(),
    tactic_summary: t.string(),
    sample_text: t.string(),
    weekly_reports: t.u32(),
  }
);

// --- delivery -----------------------------------------------------------------

export const outbox = table(
  { name: 'outbox' },
  {
    id: t.u64().primaryKey().autoInc(),
    to_e164: t.string(),
    group_key: t.string(),
    channel: t.string(), // imessage | sms | rcs | whatsapp | push
    kind: t.string(), // reply | family_alert | checkin | verification | relay | briefing | practice | system
    body: t.string(),
    priority: t.string(), // urgent | normal
    related_incident_id: t.u64(),
    recipient_contact_id: t.u64(),
    status: t.string().index('btree'), // queued | sending | sent | failed
    attempts: t.u8(),
    created_at: t.timestamp(),
  }
);

export const verification = table(
  { name: 'verification' },
  {
    id: t.u64().primaryKey().autoInc(),
    request_key: t.string().unique(),
    person_id: t.u64().index('btree'),
    contact_id: t.u64(),
    kind: t.string(), // relay | trusted_sender
    status: t.string(), // pending | confirmed | denied | expired
    deadline: t.timestamp(),
    created_at: t.timestamp(),
  }
);

export const drill = table(
  { name: 'drill' },
  {
    id: t.u64().primaryKey().autoInc(),
    person_id: t.u64().index('btree'),
    scheduled_by_contact_id: t.u64(),
    template_key: t.string(),
    send_at: t.timestamp(),
    outcome: t.string(), // pending | checked | ignored | replied
  }
);

export const briefing = table(
  { name: 'briefing' },
  {
    id: t.u64().primaryKey().autoInc(),
    person_id: t.u64().index('btree'),
    week_start: t.timestamp(),
    summary_text: t.string(),
    spoken_text: t.string(),
    created_at: t.timestamp(),
  }
);

// --- scheduled job tables -------------------------------------------------------

export const verificationDeadlineJob = table(
  { name: 'verification_deadline_job' },
  { scheduled_id: t.u64().primaryKey().autoInc(), scheduled_at: t.scheduleAt(), verification_id: t.u64() }
);

export const familyAckJob = table(
  { name: 'family_ack_job' },
  { scheduled_id: t.u64().primaryKey().autoInc(), scheduled_at: t.scheduleAt(), incident_id: t.u64() }
);

export const checkinJob = table(
  { name: 'checkin_job' },
  {
    scheduled_id: t.u64().primaryKey().autoInc(),
    scheduled_at: t.scheduleAt(),
    incident_id: t.u64(),
    kind: t.string(), // critical_1h | critical_morning
  }
);

/**
 * Work for the agent service. SpacetimeDB refuses procedure HTTP to private/loopback
 * addresses, so instead of calling out, due jobs become agent_task rows that the agent
 * service polls (svc_agent_task), claims and completes (D7: services connect as clients).
 */
export const agentTask = table(
  { name: 'agent_task' },
  {
    id: t.u64().primaryKey().autoInc(),
    workflow: t.string(),
    payload_json: t.string(),
    status: t.string().index('btree'), // queued | running | done | failed
    attempts: t.u8(),
    created_at: t.timestamp(),
    claimed_at: t.timestamp(),
    finished_at: t.timestamp(),
  }
);

export const agentTaskTimeoutJob = table(
  { name: 'agent_task_timeout_job' },
  { scheduled_id: t.u64().primaryKey().autoInc(), scheduled_at: t.scheduleAt(), task_id: t.u64() }
);

/** Delays agent work until it is due (e.g. the High check-in), then enqueues an agent_task. */
export const agentJob = table(
  { name: 'agent_job' },
  {
    scheduled_id: t.u64().primaryKey().autoInc(),
    scheduled_at: t.scheduleAt(),
    workflow: t.string(),
    payload_json: t.string(),
  }
);

export const briefingTick = table(
  { name: 'briefing_tick' },
  { scheduled_id: t.u64().primaryKey().autoInc(), scheduled_at: t.scheduleAt() }
);

export const purgeTick = table(
  { name: 'purge_tick' },
  { scheduled_id: t.u64().primaryKey().autoInc(), scheduled_at: t.scheduleAt() }
);

const spacetimedb = schema(
  {
    serviceAccount,
    person,
    contact,
    optOut,
    inboundMessage,
    messageCheck,
    incident,
    recoveryStep,
    communityReport,
    reportVote,
    reportEvidence,
    campaign,
    outbox,
    verification,
    drill,
    briefing,
    verificationDeadlineJob,
    familyAckJob,
    checkinJob,
    agentJob,
    agentTask,
    agentTaskTimeoutJob,
    briefingTick,
    purgeTick,
  },
  {
    // Wire names are exactly as written (default SnakeCase turns phone_e164 into phone_e_164).
    CASE_CONVERSION_POLICY: CaseConversionPolicy.None,
    env: {
      SERVICE_CLAIM_KEY: t.string(),
      DEMO_MODE: t.option(t.string()),
      APP_DISPLAY_NAME: t.option(t.string()),
    },
  }
);

export default spacetimedb;
