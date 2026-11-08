# Kavach — component contracts

The spec is `ScamShield Mesh Build Requirements for Claude Code.md` at the repo root (product renamed to
**Kavach**; the display name lives only in `APP_DISPLAY_NAME`). This file pins the wire contracts between
components. The SpacetimeDB module in `spacetime/src/` is the source of truth; if this file and the
module disagree, the module wins.

## 1. SpacetimeDB over HTTP (all clients)

Every component talks to SpacetimeDB through its HTTP API (decision for "verify early": there is no
official Swift SDK, so the iOS app uses HTTP too; Python services also use HTTP).

| Action | Request |
| --- | --- |
| New identity | `POST {SPACETIME_URI}/v1/identity` → `{"identity": "...", "token": "..."}` |
| Call a reducer | `POST {SPACETIME_URI}/v1/database/{SPACETIME_DB_NAME}/call/{reducer}` with `Authorization: Bearer <token>`, `Content-Type: application/json`, body = JSON object of named args. 200 = committed. Non-2xx body is the error text (e.g. `530 unknown contact`). |
| Read | `POST .../sql` with the bearer token and a raw SQL string body, e.g. `SELECT * FROM svc_outbox WHERE status = 'queued'`. `WHERE` and column lists work on views. Response: `[{"schema":{"elements":[{"name":{"some":"id"},...}]},"rows":[[...],...]}]` — zip `schema.elements[i].name.some` with each row. |

**Encoding rules**

- Names on the wire are exactly as in the module (snake_case, `phone_e164` stays `phone_e164`).
- `u64`/`i64` are plain JSON numbers (ids are small). Pass `0` for "no id".
- Timestamps come back as `[micros_since_unix_epoch]` (a one-element array). `[0]` means "unset".
- Strings use `""` for "unset". Arrays of strings are JSON arrays.
- Reducers return nothing. Reducers that create rows take a caller-generated `request_key` (UUID); read
  the new row back with `SELECT * FROM <view> WHERE request_key = '<key>'`.
- Polling is the subscription strategy for HTTP clients (photon-worker polls the outbox every 500 ms).

**Identities and tokens**

- Services: `npm run tokens` (repo root) mints one identity per role (`admin`, `agents`, `photon`, `voice`),
  binds it with `claim_service(role, key)`, and writes `.spacetime-tokens.json`. Services read
  `SPACETIME_TOKEN_<ROLE>` from env, else that file.
- iOS app: `POST /v1/identity` once, keep the token in the Keychain, then `register_person(phone, name)`.
  (MVP: phone ownership is not SMS-verified yet.)

## 2. Reducers (args are JSON object keys)

App = iOS app acting for its own person. Svc = any service identity (role in brackets when restricted).

| Reducer | Args | Caller |
| --- | --- | --- |
| `register_person` | `phone, name` | App |
| `ensure_person` | `phone, name` | Svc [photon, voice, agents] |
| `update_settings` | `person_id, accessibility_mode, sharing_paused, critical_overrides_pause, practice_consent, apns_token, family_code_word, tz_offset_minutes` | App, Svc |
| `set_sharing_paused` | `person_id, paused` | App, Svc |
| `upsert_contact` | `person_id, contact_id (0=new), name, phone_e164, relationship, channel, is_emergency_contact` | App, Svc |
| `remove_contact` | `contact_id` | App, Svc |
| `set_contact_consent` | `contact_id, consent_status` (invited/accepted/declined) | Svc [photon, agents] |
| `opt_out_number` | `phone, opt_out (bool)` | Svc, or App for its own number |
| `record_inbound_message` | `photon_message_id, from_e164, channel, body` | Svc [photon] — idempotent |
| `save_message_check` | `request_key, person_id, source, content, model_verdict, reason, campaign_id, sender_e164, link_domains[], similarity_floor, tactics[], evidence_count` | Svc [agents] — applies community floor |
| `add_report_evidence` | `source, channel, sender_e164, links[], claimed_identity, tactics[], text, verdict, campaign_id` | Svc [agents, voice] |
| `report_number` | `person_id, kind (number/link/phrase), value` | App, Svc |
| `open_incident` | `request_key, person_id (0 only for svc), entry_point, caller_e164` | App, Svc |
| `save_answer` | `incident_id, question_id, answer` | App, Svc |
| `set_incident_context` | `incident_id, tactics[], campaign_id` | Svc [agents, voice] |
| `resolve_incident` | `incident_id` | App, Svc |
| `mark_step_done` | `step_id, done` | App, Svc |
| `family_ack` | `incident_id, contact_id` | Svc [photon, agents] |
| `tell_my_family` | `incident_id` | App, Svc |
| `enqueue_outbox` | `to_e164, channel, kind, body, priority, related_incident_id, recipient_contact_id, group_key` | Svc [agents, photon, voice] |
| `mark_outbox_status` | `outbox_id, status, channel ("" = unchanged)` | Svc [photon, agents] |
| `start_verification` | `request_key, person_id, contact_id, kind (relay/trusted_sender)` | App, Svc |
| `resolve_verification` | `verification_id, result (confirmed/denied)` | Svc, or the relative's App |
| `schedule_drill` | `person_id, contact_id, template_key, send_at_micros` | App (person or linked relative), Svc |
| `record_drill_outcome` | `drill_id, outcome` | App, Svc |
| `save_briefing` | `person_id, week_start_micros, summary_text, spoken_text` | Svc [agents] — also texts it |
| `request_briefing` | `person_id` | App, Svc |

**Interview answers** (`save_answer`): `q_identity` free text · `q_ask` `yes|no|agreed` (agreed = agreed
to a callback or payment) · `q_shared` comma list of `code,pin,password,card,gift_card,money,remote_app,personal_details,link` or `nothing` ·
`q_secrecy` `yes|no` · `q_help` `yes|no` · optional `q_engaged` `yes|no` (no = declined/blocked) ·
optional `q_summary` free text (redacted call summary). Severity is computed in the module only (D2).

**Outbox field values**: `channel` imessage|sms|rcs|whatsapp|push · `kind` reply|family_alert|checkin|verification|relay|briefing|practice|system ·
`priority` urgent|normal · `status` queued|sending|sent|failed. Family alerts for one incident share
`group_key = family:<person_id>:<incident_id>`. Bodies ≤ 600 chars (briefing ≤ 1200).

## 3. Views (read with SQL)

| View | Who sees rows |
| --- | --- |
| `my_person`, `my_contacts`, `my_incidents`, `my_recovery_steps`, `my_checks`, `my_briefings`, `my_drills`, `my_pending_verifications` | The app identity that owns the person (pending verifications: where the app user is the relative being asked) |
| `caller_labels` (`value, reporter_count`) | Everyone — Call Directory feed |
| `campaign` (table) | Everyone |
| `svc_person`, `svc_contact`, `svc_incident`, `svc_recovery_step`, `svc_message_check`, `svc_community_report`, `svc_report_evidence`, `svc_outbox`, `svc_inbound_message`, `svc_verification`, `svc_drill`, `svc_briefing`, `svc_opt_out` | Service identities only (others get zero rows) |

## 4. Agent service HTTP API (`agents/`, default `http://127.0.0.1:8088`)

All `/run/*` and `/push` calls need `Authorization: Bearer {AGENT_SERVICE_TOKEN}`. `/app/*` calls use the
**app's SpacetimeDB token** as bearer; the service resolves the person by querying `my_person` with it.
Every response is JSON validated against `shared/schemas/<workflow>.output.json`. 20 s budget, then a
safe fallback (spec 13). Writes go only through reducers; replies go only through `enqueue_outbox`.

| Endpoint | Body | Returns |
| --- | --- | --- |
| `GET /health` | – | `{"ok": true}` |
| `POST /run/router` | `{text, from_e164, channel, person_id, mode: "text"|"voice"}` | `{intent, args}` — intents: scam_check, verify_relative, interview, pause, resume, stop, help, out_of_scope |
| `POST /run/scam_check` | `{person_id, text, sender_e164?, source, reply_to_e164?, reply_channel?, image_base64?}` | `{verdict, reason, campaign_id, tips[], evidence_count}`; queues the reply when `reply_to_e164` is set |
| `POST /run/interview` | `{incident_id, mode: "text"|"app"|"voice", utterance?, checkin?}` | `{next_question?, question_id?, say?, done, severity}` — in voice mode it extracts answers from free speech and saves them |
| `POST /run/family_alert` | `{incident_id, priority}` | `{alerts:[{contact_id, body}]}` |
| `POST /run/verify_relative` | `{person_id, relative_name, claim_from_e164?}` | `{verification_id, messages[]}` |
| `POST /run/trusted_sender` | `{person_id, contact_id, message_text}` | `{verification_id}` (Stretch) |
| `POST /run/briefing` | `{person_id}` | `{summary_text, spoken_text}` |
| `POST /run/practice` | `{drill_id}` | `{body}` (Stretch) |
| `POST /push` | `{to_e164, title, body, category, verification_id?}` | `{sent: bool}` — APNs delivery for `push` outbox rows |
| `POST /app/check` | `{text, source: "app_paste"|"share"|"screenshot", sender_e164?}` | same as scam_check (no text reply queued) |
| `POST /app/verify` | `{relative_name}` | same as verify_relative |

**Scheduled work uses a task queue, not procedure HTTP.** SpacetimeDB refuses procedure HTTP to
private/loopback addresses, so the module never calls out. Due work (family_alert, interview check-ins,
briefing, practice) becomes an `agent_task` row; the agent service polls `svc_agent_task WHERE status =
'queued'`, calls `claim_agent_task {task_id}`, runs the workflow, then `complete_agent_task {task_id, ok,
error}`. Failure, or no completion within 20 s, marks the task failed; for `family_alert` the module then
queues the template alert (spec 13).

**Interview responses** (all modes) also carry the section 7a result for the described call:
`verdict, reason, evidence_count, campaign_id, alert_sent`. In text mode the agent service queues its own
reply via `enqueue_outbox` (D6); app and voice modes only return it. Voice sends `channel: "voice"`.

**Corpus ownership:** the module writes one `report_evidence` row per incident (keyed by `incident_id`)
when severity reaches Medium or above, using `summary_redacted` (`q_summary`). Workflows tag incidents
with `set_incident_context`; they call `add_report_evidence` only for non-incident evidence.

## 5. Community-informed detection (spec section 7a)

`scam_check` (and call checks) must: extract signals → exact matches against `svc_community_report` →
similarity search over `svc_report_evidence.text_redacted` and `campaign.sample_text` (NIM embeddings
`MODEL_EMBED`, lexical fallback) → LLM classifies with the evidence → apply the floor → call
`save_message_check` with `similarity_floor` and `link_domains` (the module recomputes exact-match floors
and keeps the max). Users never see raw reports, only verdict and reason.

## 6. Photon worker (`photon-worker/`)

Polls `svc_outbox WHERE status = 'queued'` (urgent first, oldest first), sets `sending`, delivers, then
`sent`/`failed` via `mark_outbox_status`. `push` rows go to the agent service `/push`. Retries 5/15/45 s;
iMessage → SMS once; groups rows sharing a `group_key` into one iMessage group when every recipient is on
iMessage. Inbound: `record_inbound_message`, local text commands, else `/run/router`.
