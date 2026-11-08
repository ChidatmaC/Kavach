# ScamShield Mesh: Build Requirements for Claude Code

Nov 8, 2026 · @Chandra Sekhar Chaganti

## 1. Purpose and scope

This document is the build specification for the ScamShield Mesh hackathon project. Claude Code should treat every decision in sections 2 to 11 as settled, build in the milestone order in section 15, and raise questions only on the items listed as "verify early."

**Product in one sentence.** ScamShield turns every scam report into a live warning that protects the reporter's family and friends, through an AI agent people can text or call, alerts that reach every chosen family contact, and an iPhone app for checking things and following up.

**Goals for the hackathon build:**

- A working end-to-end demo on real iPhones, driven by real messages and a real phone call.
- Innovation first: the AI scam hotline, the Family Safety Thread, Verify a relative, Trusted Sender Check and practice scams.
- Feature-packed but stable: every Core feature works; Stretch features are added only after Core passes its acceptance checks.
- An app for everyone, with an optional Accessibility Mode for older or less confident users.

**Non-goals:**

- Reading anyone's existing iMessage, WhatsApp or SMS history.
- Listening to or recording phone calls, or reading call history.
- Any carrier data or carrier integration.
- Android, web dashboards or production-scale infrastructure.
- General-purpose chat. The agent only handles scams and safety.

**Scope labels used throughout:** **Core** must work in the demo. **Stretch** is built only after all Core acceptance checks pass.

**Product name.** "ScamShield" is a placeholder, because T-Mobile already uses that name. Keep the name in one config value (`APP_DISPLAY_NAME`) so it can be changed everywhere at once.

## 2. Constraints and settled decisions

These are fixed. Do not substitute other services or change the approach without an explicit request.

**Platform constraints (iPhone, third-party app):**

| Capability | Available? | Design response |
| --- | --- | --- |
| Read iMessage, WhatsApp or SMS history | No | People forward what worries them to the agent |
| Hear call audio or see call history | No | People describe calls by voice or in the interview |
| Label incoming callers | Yes, Call Directory extension | Community scam labels |
| Filter texts from unknown senders | Yes, Message Filter extension | Send likely scams to Junk (Stretch) |
| Report calls from Recents | Yes, Unwanted Communication extension | Host the incident interview. SMS reporting is reported broken on iOS 26, so calls only |
| Siri, Shortcuts, Action Button, Back Tap | Yes, App Intents | One-press Call Companion and "Is this a scam?" |
| Push notifications | Yes, APNs | Trusted Sender Check and alerts to app users |

**Architecture decisions:**

| # | Decision | Detail |
| --- | --- | --- |
| D1 | SpacetimeDB is the backend | One module holds all state; every write goes through a reducer; schedules run in the database |
| D2 | Severity is rule-based | A reducer sets severity from interview answers. The LLM never sets or lowers it |
| D3 | Nemotron runs the agent workflows | NVIDIA NeMo Agent Toolkit (Python) with router and ReAct agents; models via the hosted NIM API at build.nvidia.com |
| D4 | Two model tiers | Nemotron 3 Nano for routing, classification and tool loops; a larger Nemotron model for text people read |
| D5 | Photon is the only messaging gateway | A single TypeScript worker using Photon Spectrum handles iMessage, plus SMS and RCS fallback |
| D6 | The outbox is the only way out | Agents never send messages directly. They write outbox rows; the Photon worker delivers them |
| D7 | No inbound webhooks into SpacetimeDB | The Photon worker and voice service connect as SpacetimeDB clients and call reducers |
| D8 | Hotline uses Pipecat | Telephony number, speech to text, router and interview workflows, text to speech |
| D9 | iPhone app is a thin client | SwiftUI plus four extensions; six screens; no business logic beyond display and input |
| D10 | Recovery steps come from a vetted library | The LLM only words them; it cannot invent new steps |
| D11 | Guardrails via NeMo Guardrails | Scam and safety topics only; never request codes or payment; no message contents in family alerts |
| D12 | Accessibility Mode is optional | Off by default; changes presentation, never removes features |
| D13 | Family alerts reach every chosen contact | One iMessage group when all members use iMessage; otherwise individual SMS or RCS; WhatsApp is Stretch |
| D14 | Detection is community-informed search plus LLM | Every message and call check first searches the community report corpus (exact and similarity matches), then the LLM classifies with that evidence in context. See section 7a |
| D15 | Community reports are internal | The report corpus is readable only by service identities. People see verdicts and reasons, never raw reports. Caller labels expose only a number and a count |

## 3. System architecture

Five deployable components, connected only through SpacetimeDB and one HTTP API on the agent service.

| Component | Language | Responsibility | Talks to |
| --- | --- | --- | --- |
| `spacetime` module | TypeScript | All tables, reducers, scheduled jobs, procedures | Called by every other component; procedures call the agent service and APNs |
| `agents` service | Python, NeMo Agent Toolkit | All Nemotron workflows; exposes `POST /run/{workflow}` | Reads and writes SpacetimeDB through its client SDK; calls NIM |
| `photon-worker` | TypeScript, Photon Spectrum | Inbound and outbound texts | Photon; SpacetimeDB client; agent service |
| `voice` service | Python, Pipecat | The hotline | Telephony provider; agent service; SpacetimeDB client |
| `ios` app | Swift, SwiftUI | Six screens and four extensions | SpacetimeDB (client SDK or HTTP API) and the agent service |

**Inbound text flow:**

1. Photon delivers a message to `photon-worker`.
2. The worker calls reducer `record_inbound_message`, then calls `POST /run/router` on the agent service.
3. The router picks a workflow; the workflow calls its tools, which read SpacetimeDB and write through reducers.
4. Every reply is written as an `outbox` row.
5. `photon-worker`, subscribed to `outbox` rows with status `queued`, sends each one and calls `mark_outbox_status`.

**Scheduled flow:** a scheduled reducer fires, such as a verification deadline. If it needs AI or a push notification, it starts a procedure that calls the agent service or APNs. Results land as new rows, usually in `outbox`.

**Feature map: outside the app vs in the app**

| Outside the app (real time) | In the app (six screens) |
| --- | --- |
| Caller labels on the incoming call screen | Home: status and three actions |
| Unknown-sender text filter (Stretch) | Check a message: paste or screenshot, then verdict |
| ScamShield contact in iMessage | Call Companion: full-screen prompts, interview after the call |
| AI scam hotline | Act now: recovery checklist |
| Report-swipe interview in Recents | Family: contacts, code word, pause, practice scheduling |
| Call Companion launch via Action Button, Back Tap, Siri | Settings: Accessibility Mode, extensions, shortcuts |
| Family Safety Thread alerts |  |
| Verify a relative |  |
| Trusted Sender Check push (Stretch) |  |
| Threat-level follow-ups and check-ins |  |
| Practice scams (Stretch) and weekly briefing |  |

The alerts feed and past briefings live in a "This week" section on Home, not in separate tabs.

## 4. Repository layout and tech stack

One monorepo. Each component builds and runs on its own, and shared definitions live in `shared/`.

```
scamshield/
  CLAUDE.md                  # short pointer to this spec and the run commands
  .env.example               # every secret and config value, no real values
  shared/
    schemas/                 # JSON Schemas for agent outputs and outbox payloads
    recovery_library.yaml    # vetted recovery steps (D10)
    prompts/                 # one file per workflow prompt
    seed/                    # demo personas, numbers, campaigns
  spacetime/                 # SpacetimeDB module (TypeScript)
    src/tables.ts
    src/reducers/
    src/schedules.ts
    src/procedures.ts
  agents/                    # NeMo Agent Toolkit service (Python)
    configs/                 # one NAT YAML per workflow
    tools/                   # SpacetimeDB read and reducer tools, link checker
    guardrails/              # NeMo Guardrails config
    server.py                # POST /run/{workflow}
  photon-worker/             # Photon Spectrum worker (TypeScript)
    src/inbound.ts
    src/commands.ts
    src/outbox.ts
  voice/                     # Pipecat hotline (Python)
    pipeline.py
  ios/                       # Xcode project
    ScamShield/              # SwiftUI app
    CallDirectoryExtension/
    MessageFilterExtension/
    ReportExtension/         # Unwanted Communication extension
    ShareExtension/
  scripts/
    seed.ts                  # loads shared/seed into SpacetimeDB
    demo_reset.ts
```

| Component | Stack |
| --- | --- |
| spacetime | SpacetimeDB TypeScript module; typed environment variables for secrets |
| agents | Python 3.11+, NeMo Agent Toolkit, NeMo Guardrails, SpacetimeDB Python client or HTTP API, NIM via its OpenAI-compatible endpoint |
| photon-worker | Node 20+, TypeScript, Photon Spectrum SDK, SpacetimeDB TypeScript client |
| voice | Python 3.11+, Pipecat, a telephony provider, speech-to-text and text-to-speech services supported by Pipecat |
| ios | iOS 26 target, Swift 6, SwiftUI, IdentityLookup, CallKit, App Intents, UserNotifications, AVFoundation for speech |

**Configuration (`.env.example` keys):** `APP_DISPLAY_NAME`, `SPACETIME_URI`, `SPACETIME_DB_NAME`, `NIM_API_KEY`, `NIM_BASE_URL`, `MODEL_FAST` (Nemotron 3 Nano), `MODEL_WRITER` (larger Nemotron), `MODEL_EMBED` (NIM embedding model for section 7a), `PHOTON_API_KEY`, `PHOTON_AGENT_LINE`, `AGENT_SERVICE_URL`, `AGENT_SERVICE_TOKEN`, `TELEPHONY_*`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `DEMO_MODE`.

## 5. SpacetimeDB data model

All tables live in one module. IDs are auto-incrementing integers unless noted. Timestamps use SpacetimeDB's timestamp type. Phone numbers are stored in E.164 format.

```ts
person {
  id: u64 (pk)
  phone_e164: string (unique)
  display_name: string
  accessibility_mode: bool = false
  sharing_paused: bool = false
  critical_overrides_pause: bool = false   // chosen at setup
  practice_consent: bool = false
  apns_token: string | null
  recovery_watch_until: timestamp | null   // set by Critical
  campaign_watch_until: timestamp | null   // set by High
  created_at: timestamp
}

contact {
  id: u64 (pk)
  person_id: u64 (index)
  name: string
  phone_e164: string (index)
  relationship: string
  channel: "imessage" | "sms" | "rcs" | "whatsapp"
  is_emergency_contact: bool
  is_app_user: bool                        // enables Trusted Sender Check
  linked_person_id: u64 | null
  consent_status: "invited" | "accepted" | "declined"
}

inbound_message {
  id: u64 (pk)
  from_e164: string (index)
  person_id: u64 | null
  channel: string
  body: string
  photon_message_id: string (unique)       // idempotency
  received_at: timestamp
}

message_check {
  id: u64 (pk)
  person_id: u64 (index)
  source: "imessage" | "share" | "app_paste" | "screenshot"
  content_redacted: string                 // codes, card and account numbers masked
  verdict: "safe" | "suspicious" | "likely_scam"
  reason: string
  campaign_id: u64 | null
  created_at: timestamp
}

incident {
  id: u64 (pk)
  person_id: u64 (index)
  entry_point: "report_swipe" | "companion" | "hotline" | "imessage" | "app"
  caller_e164: string | null
  claimed_identity: string | null
  answers_json: string                     // keyed by question id
  tactics: string[]
  shared_items: string[]                   // code, pin, password, card, gift_card, money, remote_app, personal_details, link
  severity: "low" | "medium" | "high" | "critical" | null
  status: "open" | "in_progress" | "resolved"
  family_ack_by: u64 | null                // contact id who tapped "I'm calling"
  created_at: timestamp
  resolved_at: timestamp | null
}

recovery_step {
  id: u64 (pk)
  incident_id: u64 (index)
  step_key: string                         // key into recovery_library.yaml
  priority: "now" | "today" | "this_week"
  done: bool
}

community_report {
  id: u64 (pk)
  kind: "number" | "link" | "phrase"
  value: string (unique per kind)
  campaign_id: u64 | null
  reporter_count: u32
  label_visible: bool                      // true when reporter_count >= LABEL_THRESHOLD
  last_reported_at: timestamp
}

report_vote { report_id: u64, person_id: u64 }   // unique pair; prevents double counting

report_evidence {                          // D14: the searchable corpus, service-only (D15)
  id: u64 (pk)
  report_id: u64 | null                    // linked number/link/phrase report, if any
  source: "message" | "call" | "hotline" | "seed"
  channel: string                          // sms, imessage, call, ...
  sender_e164: string | null
  links: string[]                          // normalized URLs and registrable domains
  claimed_identity: string | null
  tactics: string[]
  text_redacted: string                    // redacted message text or call script summary
  verdict: "suspicious" | "likely_scam"
  campaign_id: u64 | null
  created_at: timestamp
}

campaign {
  id: u64 (pk)
  title: string
  tactic_summary: string
  sample_text: string
  weekly_reports: u32
}

outbox {
  id: u64 (pk)
  to_e164: string | null
  group_key: string | null                 // family group thread
  channel: "imessage" | "sms" | "rcs" | "whatsapp" | "push"
  body: string
  priority: "urgent" | "normal"
  related_incident_id: u64 | null
  status: "queued" | "sending" | "sent" | "failed"
  attempts: u8
  created_at: timestamp
}

verification {
  id: u64 (pk)
  person_id: u64
  contact_id: u64
  kind: "relay" | "trusted_sender"
  status: "pending" | "confirmed" | "denied" | "expired"
  deadline: timestamp
}

drill {
  id: u64 (pk)
  person_id: u64
  scheduled_by_contact_id: u64
  template_key: string
  send_at: timestamp
  outcome: "pending" | "checked" | "ignored" | "replied"
}

briefing { id, person_id, week_start, summary_text, created_at }
```

**Constants:** `LABEL_THRESHOLD = 3` independent reporters; `VERIFY_DEADLINE = 5 min`; `FAMILY_ACK_DEADLINE = 10 min`; `HIGH_CHECKIN_DELAY = 1 h`; `CRITICAL_WATCH_DAYS = 30`; `HIGH_WATCH_DAYS = 14`.

**Access rules:**

- A client identity can read only its own `person`, its `contact` rows, its incidents, recovery steps, checks and briefings.
- Caller labels (number and reporter count only, where `label_visible = true`) and `campaign` rows are readable by everyone.
- `community_report`, `report_vote`, `report_evidence`, `outbox`, `inbound_message` and `verification` are readable only by the service identities used by `photon-worker`, `agents` and `voice` (D15).
- Raw message bodies are never stored in `message_check`. Only the redacted version is kept, and `inbound_message.body` is deleted after 7 days.

## 6. Reducers, procedures and schedules

Reducers validate input and reject anything invalid; they never call the network. Anything needing HTTP runs in a procedure.

**Reducers:**

| Reducer | Caller | Behavior |
| --- | --- | --- |
| `register_person(phone, name)` | iOS app | Creates `person` for the caller's identity |
| `update_settings(...)` | iOS app | Accessibility Mode, pause, critical override, practice consent, APNs token |
| `upsert_contact(...)` / `remove_contact(id)` | iOS app | Manage family contacts; new contacts start as `invited` |
| `record_inbound_message(...)` | photon-worker | Inserts `inbound_message`; ignores duplicate `photon_message_id` |
| `save_message_check(...)` | agents | Inserts a check with redacted content and verdict |
| `open_incident(person, entry_point, caller?)` | iOS app, agents, voice | Creates an `open` incident and returns its id |
| `save_answer(incident, question_id, answer)` | iOS app, agents, voice | Updates `answers_json`, then calls the severity rules (section 8) |
| `set_severity(incident)` | Internal only | Applies rules; severity can only go up; on change, triggers the level workflow |
| `resolve_incident(incident)` | iOS app | Only path that lowers or closes an incident |
| `mark_step_done(step)` | iOS app | Ticks a recovery step; resolves the incident when all `now` and `today` steps are done |
| `family_ack(incident, contact)` | photon-worker | Records who replied "I'm calling" |
| `report_number(value, kind)` | iOS app, agents | Adds a `report_vote` once per person; recomputes `label_visible` |
| `add_report_evidence(...)` | agents, voice | Inserts a redacted `report_evidence` row (section 7a); service identities only |
| `enqueue_outbox(...)` | agents, schedules | Inserts a `queued` row; refuses family alerts when `sharing_paused` unless Critical and override is set |
| `mark_outbox_status(id, status)` | photon-worker | Updates status and attempts |
| `start_verification(...)` / `resolve_verification(id, result)` | agents, photon-worker, iOS app | Creates with deadline; resolves from a reply or push response |
| `schedule_drill(...)` / `record_drill_outcome(...)` | iOS app, agents | Requires `practice_consent` |

**Scheduled jobs:**

| Job | Fires | Action |
| --- | --- | --- |
| `verification_deadline` | `VERIFY_DEADLINE` after start | If still pending, set `expired` and queue "Not confirmed" messages |
| `family_ack_deadline` | 10 min after a Critical alert | If no ack, resend the urgent alert and queue a prompt to call the hotline |
| `high_checkin` | 1 h after High | Procedure calls the interview workflow to ask "Did anything else happen?" |
| `critical_checkins` | 1 h and next morning at 9 am local | Queue check-in messages |
| `weekly_briefing` | Sunday 6 pm local | Procedure calls the briefing workflow per person |
| `drill_send` | `drill.send_at` | Procedure calls the practice workflow, which queues the practice text |
| `purge_inbound` | Daily | Deletes `inbound_message.body` older than 7 days |

**Procedures (outbound HTTP):**

- `call_agent(workflow, payload)` posts to `AGENT_SERVICE_URL/run/{workflow}` with `AGENT_SERVICE_TOKEN`.
  - **Build note (Nov 8):** SpacetimeDB refuses procedure HTTP to private or loopback addresses, so the build replaces `call_agent` with an `agent_task` queue: due work becomes a row that the agent service polls, claims and completes as a client (in the spirit of D7). No completion within 20 s marks the task failed and applies the section 13 fallback. See `docs/CONTRACTS.md`.
- `send_push(person, title, body, category)` calls APNs over HTTP/2 with the token key. It is used for Trusted Sender Check and for urgent alerts to app users.

Secrets come from the module's typed environment variables, never from code.

## 7. Nemotron agent workflows

The `agents` service hosts every workflow on NeMo Agent Toolkit and exposes `POST /run/{workflow}`, authenticated with `AGENT_SERVICE_TOKEN`. Each workflow is a NAT YAML config in `agents/configs/`. Every workflow returns JSON that validates against a schema in `shared/schemas/`; invalid output is retried once, then falls back to a safe default.

**Agent rules for all workflows:**

- Cap tool calls at 6 per run.
- Writes happen only through reducer tools, never direct table access.
- `MODEL_FAST` (Nemotron 3 Nano) handles routing, classification and tool loops; `MODEL_WRITER` writes any text a person reads.
- Before saving, redact codes, card numbers and account numbers from stored text.
- Never ask for a code, PIN, password or payment.

**Shared tools:**

| Tool | Does |
| --- | --- |
| `lookup_community(value)` | Returns report count, label status and campaign for a number, link or phrase |
| `search_community(query)` | Community-informed search (section 7a): returns ranked evidence for a message or call description |
| `check_link(url)` | Heuristics: risky web address endings, brand word plus hyphen, lookalike spelling, URL shorteners |
| `get_person(id)` / `get_contacts(person_id)` | Read profile, settings and contacts |
| `get_incident(id)` | Read an incident with answers |
| `reducer(name, args)` | Calls an allowed reducer; the allowlist is per workflow |
| `recovery_steps(shared_items)` | Returns step keys from `recovery_library.yaml` |

**Workflows:**

| Workflow | Input | Steps | Output schema |
| --- | --- | --- | --- |
| `router` | Inbound text with sender context, or a hotline turn | Classify intent: `scam_check`, `verify_relative`, `interview`, `pause`, `resume`, `stop`, `help`, `out_of_scope` | `{intent, args}` |
| `scam_check` | Text or screenshot text, sender | Run `search_community`, check links, classify with the evidence, apply the community floor, write verdict and evidence, queue reply | `{verdict, reason, campaign_id?, tips[], evidence_count}` |
| `interview` | Incident id and the latest answer | Ask the next unanswered question, save the answer, stop after 5 questions or at Critical | `{next_question?, done}` |
| `family_alert` | Incident id | Read incident and contacts, write one explained alert, queue it per contact channel | `{alerts: [{contact_id, body}]}` |
| `verify_relative` | Person, named relative | Find contact; if the claim came from an unknown number, text the relative's saved number; if from the relative's own number, prompt a direct call and ask another family member; start the deadline | `{verification_id, messages[]}` |
| `trusted_sender` (Stretch) | Flagged message from a contact who is an app user | Start a verification and push "Did you send this?" to their app | `{verification_id}` |
| `briefing` | Person, week | Summarize incidents and checks, add one habit and nearby campaigns | `{summary_text, spoken_text}` |
| `practice` (Stretch) | Drill id | Pick a template, write a harmless practice text, queue it | `{body}` |

## 7a. Community-informed detection (D14, D15)

Scam detection for messages and calls is an informed search over communal scam reports combined with LLM analysis. The reports are internal evidence, not user-facing content.

**Search (`search_community`)**, run before any classification:

1. Extract signals from the input: sender number, URLs (normalized, plus registrable domain), claimed identity, and redacted text.
2. Exact matches: sender or caller number and link domains against `community_report` (reporter counts, campaign).
3. Similarity matches: the redacted text against `report_evidence.text_redacted` and `campaign.sample_text`, using NIM embeddings (`MODEL_EMBED`) with a lexical fallback when embeddings are unavailable. Return the top 5 above a similarity threshold.
4. Return ranked evidence: match kind, score, reporter count, campaign, tactics. Never raw report text from other people beyond the redacted excerpt, and only to the model.

**Classification:** the LLM receives the input plus the evidence and returns a verdict, reason and tactics. The reason may say "this matches a pattern many people have reported" but must not quote other people's reports.

**Community floor (like D2):** the model can raise a verdict but never lower it below the evidence floor:

| Evidence | Minimum verdict |
| --- | --- |
| Exact number or link domain with `reporter_count >= LABEL_THRESHOLD` | likely_scam |
| Exact match below threshold, or similarity >= 0.85 to a likely_scam report or campaign | suspicious |
| `recovery_watch_until` active and message is about recovering money or refunds | likely_scam |

**Calls:** the incoming-call label uses exact number matches. Call Companion, the interview and the hotline run `search_community` on the caller number plus the described script (claimed identity, asks, tactics), and the result informs the verdict read back to the person.

**Feedback loop:** every `suspicious` or `likely_scam` check and every incident at Medium or above writes a `report_evidence` row (redacted) through reducer `add_report_evidence`, and counts sender numbers and link domains through `report_number`. This is how the corpus grows.

**Acceptance:** a message never seen before that paraphrases a seeded campaign returns at least "suspicious", citing the community pattern; a fresh message from a number with 3+ reporters returns "likely_scam" even if the model says safe.

**Interview questions** (ids are stable and used by the severity rules):

1. `q_identity`: Who did they say they were?
2. `q_ask`: Did they ask for money, codes, gift cards or personal details?
3. `q_shared`: Did you share or send anything? Multi-select: code, PIN or password, card details, gift card numbers, money, an app install, personal details, tapped a link, nothing.
4. `q_secrecy`: Did they ask you to keep it secret or rush you?
5. `q_help`: Do you want help right now?

**Explained family alert format** (at most 600 characters): what kind of scam; what the caller claimed; tactics used; what may have been shared; the first two precautions; and a suggested kind way to check in. It must not include message contents beyond the incident summary.

**Guardrails (NeMo Guardrails):**

- Input rail: classify off-topic requests and answer with a short scope message.
- Output rail: block any request for codes, PINs, passwords or payment.
- Output rail: block real links in practice texts.
- Output rail: block medical, legal or financial advice beyond the vetted steps.
- Output rail: practice texts may never ask for anything real.

## 8. Severity rules and threat-level workflows

The `set_severity` reducer computes the level from `q_shared` and `q_ask` with the rules below, evaluated top to bottom. Severity only goes up automatically; only `resolve_incident` lowers or closes it.

| Rule | Level |
| --- | --- |
| `q_shared` includes code, PIN or password, card details, gift card numbers, money, or an app install | Critical |
| `q_shared` includes personal details or a tapped link, or the person agreed to a callback or payment | High |
| Person engaged but `q_shared` is nothing | Medium |
| Declined, blocked, or checked with ScamShield before engaging | Low |

When the level is set or rises, the reducer runs the matching sequence.

**Critical**

1. Queue an "Act now" reply on the channel the incident came from. In the app, open the Act now screen; with Accessibility Mode on, speak it.
2. Insert `recovery_step` rows from `recovery_steps(shared_items)`, ordered `now`, `today`, `this_week`.
3. Call the `family_alert` workflow with `priority = urgent` for all accepted contacts. If sharing is paused, send only to the emergency contact, and only when `critical_overrides_pause` is true.
4. Schedule `family_ack_deadline` (10 minutes). Any contact replying "I'm calling" or "on it" triggers `family_ack`.
5. Count the caller number as a community report.
6. Schedule `critical_checkins` (1 hour and next morning).
7. Set `recovery_watch_until = now + 30 days`. During the watch, `scam_check` forces "likely scam" for any message about recovering money or refunds.
8. Queue a message offering a prefilled summary for ReportFraud.ftc.gov, and ic3.gov if online.

**High**

1. Queue a calm "Be careful" reply explaining what was shared and how it could be misused.
2. Insert matching recovery steps, such as a credit freeze for a Social Security number or a password change for a tapped link.
3. Call `family_alert` with `priority = normal`, respecting `sharing_paused`.
4. Schedule `high_checkin` (1 hour). New answers rerun the rules and may raise the level to Critical.
5. Set `campaign_watch_until = now + 14 days`. Messages from the same number or campaign are flagged automatically.
6. Count the caller number as a community report.

**Medium**

1. Queue a short verdict, praise for not sharing, and one tip about the tactic.
2. Offer one-tap block and report.
3. No family alert. It appears in the weekly briefing, and a "Tell my family" action can send it on demand.
4. Count the caller number as a community report.
5. If this is the third Medium incident from the same campaign within 7 days and practice consent is on, suggest a practice scam on that tactic.

**Low**

1. Reply with the verdict only; no other notifications.
2. Count blocked or reported numbers as community reports.
3. Include it in the weekly briefing as a win.

## 9. Photon integration

`photon-worker` is the only process that talks to Photon. It runs one managed iMessage line (`PHOTON_AGENT_LINE`) with SMS and RCS fallback.

**Inbound handling:**

1. Receive the message event from Photon Spectrum.
2. Call `record_inbound_message`; skip it if the Photon message id was already seen.
3. Match the sender to a `person`, or to a `contact` replying in a family thread.
4. Parse text commands locally first (below). Anything else goes to `POST /run/router`.
5. Images are passed to the agent service as attachments; the service runs text recognition before `scam_check`.

**Text commands** (case-insensitive, matched before the router):

| Command | From | Action |
| --- | --- | --- |
| `verify <name>` | Person | Run `verify_relative` |
| `yes`, `it's me`, `confirmed` | Relative with a pending verification | `resolve_verification(confirmed)` |
| `no`, `not me` | Relative with a pending verification | `resolve_verification(denied)` |
| `I'm calling`, `on it` | Family contact after a Critical alert | `family_ack` |
| `pause` / `resume` | Person | Toggle `sharing_paused` |
| `stop` | Anyone | Opt out of all messages from the agent; required for SMS |
| `help` | Anyone | Send the short help text |

**Outbound delivery:**

1. Subscribe to `outbox` rows with status `queued`, oldest first, with `urgent` rows before `normal`.
2. Set the row to `sending` and send it on its channel.
3. For family alerts, use one iMessage group (`group_key`) when every recipient in that family is on iMessage. Otherwise send individual messages per contact on their channel.
4. On success, call `mark_outbox_status(sent)`.
5. On failure, retry up to 3 times with backoff (5, 15, 45 seconds). If iMessage still fails, switch the row to SMS once, then mark it `failed`.
6. Replies from any family member in a non-group setup are relayed to the other members as new outbox rows, prefixed with the sender's name.

**Message style:** short, plain sentences; verdict first; no more than 2 links, which may only point to the app or official sites such as ReportFraud.ftc.gov; under 600 characters.

## 10. Voice hotline

Anyone can call the hotline number. It answers only inbound calls and never places outbound automated calls, which keeps it clear of consent rules for AI voice calls.

**Pipeline (Pipecat):** telephony number, speech to text, the `router` and `interview` workflows, then text to speech, using voice activity detection so callers can interrupt.

**Call flow:**

1. Greet the caller: "Hi, this is ScamShield. Tell me what happened, and I'll help you work out if it's a scam."
2. Match the caller ID to a `person`. Unknown callers can still use it, and their incident is saved without a person until they register.
3. Open an incident with `entry_point = hotline`.
4. Let the caller describe it freely, then ask any of the 5 interview questions not already answered.
5. Read back the verdict, the level and the first steps. For Critical, offer to stay on the line while they call their bank or carrier.
6. End with "I've told your family" when an alert was sent, or "Would you like me to tell your family?" for Medium.

**Voice requirements:**

- Speak slowly, at about 140 words per minute, with short sentences.
- Respond within 1.5 seconds after the caller stops speaking.
- Offer "Press 1 or say repeat" after every answer.
- Never ask for codes, PINs, card numbers or account numbers, and tell callers not to say them.
- Store the transcript only as a redacted summary on the incident, never the audio.

## 11. iPhone app

A thin SwiftUI client that follows Apple's Human Interface Guidelines. It has six main screens, a shared interview view and four extensions, and keeps no business logic beyond display and input.

**Screens:**

| Screen | Contents | Scope |
| --- | --- | --- |
| Home | Status card ("You're protected", scams stopped this week); three large actions: Check a message, I'm on a call, I need help; a "This week" section with recent checks, active campaigns and the latest briefing | Core |
| Check a message | Text area, Paste and Choose screenshot buttons; result shows verdict badge, one-sentence reason, highlighted phrases, "What to do", and Report and block, Tell my family, Read aloud | Core |
| Call Companion | Full-screen, high contrast; three cards: Don't share codes, Ask for our family code word, Hang up and call back on a number you know; buttons Verify this person and End and report; banner "Your family has been told you asked for help" | Core |
| Interview | One question per screen, progress (1 of 5), large answer buttons, speaker icon. Shared by the Report extension and Companion | Core |
| Act now | Red header, numbered recovery checklist from `recovery_step`, Call my family button, reassurance line | Core |
| Family | Contacts with channel and consent status; Family Safety Thread preview; Pause sharing; family code word; Verify a relative; practice scheduling (Stretch) | Core |
| Settings | Accessibility Mode toggle first; spoken verdicts, larger text, caller labels, text filter; Action Button and Back Tap setup help; critical override and practice consent | Core |

**Design rules:** a calm style with one accent color; three verdict states that always pair a color, an icon and a word (green "Looks safe", amber "Suspicious", red "Likely scam"); touch targets of at least 44 points; full Dynamic Type support; VoiceOver labels on every control; red used only for "Likely scam" and Critical.

**Accessibility Mode (optional, off by default):**

- Home shows only the three actions as full-width buttons.
- Verdicts and steps are read aloud automatically with a visible Repeat button.
- Text is larger, contrast is higher, and every tap gives haptic feedback.
- Every feature stays reachable.

**Extensions:**

| Extension | Purpose | Scope |
| --- | --- | --- |
| Call Directory | Loads numbers where `label_visible = true`, labeled "Likely scam: N reports." The app refreshes it when labels change | Core |
| Unwanted Communication (Report) | When a call is reported from Recents, shows the interview UI and calls `open_incident` and `save_answer` | Core |
| Share | Sends shared text or images to `scam_check`; shows the verdict in the share sheet | Core |
| Message Filter | Sends likely scam texts from unknown senders to Junk, using the agent's verdict | Stretch |

**App Intents and shortcuts:** "Open Call Companion" (assignable to the Action Button and Back Tap), "Check this with ScamShield", and "I need help." Expose Siri phrases for each.

**Push notifications:** register for APNs and save the token with `update_settings`. Handle the `TRUSTED_SENDER` category with Yes and No actions; the Yes action requires Face ID through LocalAuthentication before calling `resolve_verification`.

**End of call:** while Call Companion is open, observe call state with CallKit's call observer. When the call ends, speak a short check-in and open the interview. If the event doesn't arrive reliably, show an "I've hung up" button instead.

**Backend connection:** use the SpacetimeDB client SDK if a Swift client exists; otherwise use SpacetimeDB's HTTP API for reducer calls and short polling for subscriptions. As a last resort, proxy through the agent service. Decide this in Milestone 1.

## 12. Security, privacy and consent

These requirements apply to every component.

- **Consent for family sharing:** a contact receives alerts only after accepting an invite, and the protected person can pause or remove anyone at any time.
- **Practice scams:** only when `practice_consent` is true, sent by text, never asking for anything real, and revealed immediately when replied to or after 24 hours.
- **No automated outbound voice calls:** the hotline only answers calls.
- **SMS opt-out:** honor `stop` on every channel immediately.
- **Data minimization:** store redacted summaries, not raw messages or audio; purge inbound bodies after 7 days; never log codes, card numbers or full message text.
- **What family alerts can include:** the incident summary only, never the person's message contents or unrelated activity.
- **Secrets:** environment variables only, never committed; `.env.example` holds placeholders.
- **Service authentication:** separate SpacetimeDB identities for `photon-worker`, `agents` and `voice`; the agent service requires a bearer token.
- **Community labels:** count one vote per person per number, and show a label only after 3 independent reporters.
- **Scope of the agent:** scam and safety topics only, which also keeps the WhatsApp channel within Meta's business messaging policy.
- **Photon:** treat it as an external dependency with no official Apple API behind it; keep SMS as the fallback path.

## 13. Non-functional requirements

The demo is live, so speed and reliability matter more than scale.

| Requirement | Target |
| --- | --- |
| iMessage scam check, message received to reply delivered | Under 10 seconds |
| Family alert after severity is set | Under 15 seconds |
| Hotline response after the caller stops speaking | Under 1.5 seconds |
| Caller labels refreshed after a label becomes visible | Under 60 seconds while the app is open |
| Agent workflow runs | At most 6 tool calls; 20-second timeout, then a safe fallback reply |
| Outbox delivery | At-least-once, with duplicate protection by outbox id |

**Fallback replies** when a model call fails or times out:

- Scam check: "I couldn't check this right now. Don't reply or tap any links, and ask someone you trust."
- Family alert: send a template alert built from the incident fields without the model.

**Logging and observability:** structured JSON logs with workflow name, incident id, latency and outcome, with no message contents. Add a simple `/health` endpoint on the agent service and voice service.

**Demo mode (`DEMO_MODE=true`):**

- Shortens timers: verification deadline 60 seconds, family ack 90 seconds, High check-in 2 minutes.
- Uses the seeded personas, numbers and campaigns.
- Caches verdicts for the exact demo messages so a slow model can't stall the stage.
- `scripts/demo_reset.ts` restores the seeded state in one command.

## 14. Seed data and demo script

The demo uses two iPhones: **Phone A** belongs to the protected person, "Grandpa Joe," and **Phone B** belongs to his grandson "Tommy," who is also his family contact. A third team member's phone acts as the scam caller.

**Seed data (`shared/seed/`):**

- Persons: Joe (Phone A) and Tommy (Phone B, also an app user for Trusted Sender Check).
- Contacts for Joe: Tommy on iMessage, emergency contact; one more contact on SMS to show cross-platform delivery.
- Community reports: the scam caller's number with 14 reporters, so it's labeled; 3 to 5 other numbers and links.
- Campaigns: fake carrier fraud calls, unpaid toll texts, grandchild emergency calls, remote job offers.
- Demo messages with cached verdicts: a fake toll text with a risky link, a "new number, it's me" text, and a recovery-fee offer.
- Family code word: "blue pancake."

**Demo script (about 3 minutes):**

1. The scam caller rings Phone A. The incoming call screen shows "Likely scam: 14 reports."
2. Joe answers and presses the Action Button. Call Companion opens, and the SMS contact and Tommy get "Joe asked for help during a call."
3. Joe texts the agent "Verify Tommy." Phone B gets the confirmation request; Tommy replies "not me"; the family is told it was a scam.
4. Joe hangs up. The interview opens; he answers that he shared personal details. Severity is set to High.
5. The explained alert lands in Tommy's iMessage and on the SMS contact's phone.
6. Call the hotline on speaker and describe a gift card request. The voice agent gives a verdict out loud.
7. Forward the fake toll text to the ScamShield contact and show the verdict reply.
8. Stretch: a message "from Tommy's number" asks Joe for money; Phone B gets the Trusted Sender push; Tommy taps No.
9. Show the weekly briefing, then turn on Accessibility Mode to show the same app adapting.

Keep a screen recording of each step as a backup in case a network service fails on stage.

## 15. Milestones and acceptance checks

Build in this order. Don't start a milestone until the previous one's checks pass.

**Verify early (in Milestone 1, before building on them):**

- [ ] Is there a SpacetimeDB Swift client? If not, choose the HTTP API or the agent-service proxy for the app.
- [ ] Does the Photon worker receive and send on the agent line, including a group thread and SMS fallback?
- [ ] Do the hosted NIM endpoints return tool calls from Nemotron 3 Nano within the latency targets?
- [ ] Does the app receive the end-of-call event while Call Companion is open?
- [ ] Does the Unwanted Communication extension appear for calls in Recents on iOS 26?

**Milestone 1: Backbone**

- [ ] SpacetimeDB module publishes with all tables, reducers and access rules from sections 5 and 6.
- [ ] `scripts/seed.ts` loads the seed data; `demo_reset.ts` restores it.
- [ ] `photon-worker` records an inbound iMessage and delivers a queued outbox row.
- [ ] Agent service answers `GET /health` and `POST /run/router` using NIM.

**Milestone 2: Scam check and family alerts**

- [ ] Forwarding the seeded toll text returns a "Likely scam" reply in under 10 seconds.
- [ ] Community-informed detection passes the section 7a acceptance checks, and reports never appear in user-facing replies.
- [ ] A High incident creates explained alerts for Tommy on iMessage and the second contact on SMS.
- [ ] Pausing sharing blocks family alerts; Critical with the override still reaches the emergency contact.
- [ ] Guardrails block a request for a code and an off-topic question.

**Milestone 3: Interview, severity, relay and hotline**

- [ ] All five interview questions save answers, and severity follows the rules table for each `q_shared` option.
- [ ] Each level runs its sequence from section 8, including scheduled jobs with demo timers.
- [ ] "Verify Tommy" confirms, denies and expires correctly.
- [ ] The hotline completes an interview by voice and posts the family alert.

**Milestone 4: iPhone app**

- [ ] All screens in section 11 work, with VoiceOver labels and Dynamic Type.
- [ ] Call Directory shows the seeded label on an incoming call.
- [ ] Report swipe opens the interview and saves an incident.
- [ ] Action Button and Siri open Call Companion.
- [ ] Accessibility Mode changes Home and reads verdicts aloud.

**Milestone 5: Briefing, polish and stretch**

- [ ] Weekly briefing generates and delivers in text and spoken form.
- [ ] Stretch: Trusted Sender Check push with Face ID approval on Phone B.
- [ ] Stretch: practice scam sends, and replies record the outcome.
- [ ] Stretch: Message Filter extension and WhatsApp channel.
- [ ] The full demo script in section 14 runs twice in a row after `demo_reset`.
