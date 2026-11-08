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

- Services: `npm run tokens` (repo root) mints one identity per role (`admin`, `agents`, `photon`; the module
  still accepts a `voice` role, unused since section 7), binds it with `claim_service(role, key)`, and
  writes `.spacetime-tokens.json`. Services read `SPACETIME_TOKEN_<ROLE>` from env, else that file.
- iOS app: `POST /v1/identity` per sign-in, then `request_sign_in(phone, name)` (texts a 6-digit code) and
  `verify_sign_in(phone, code)`; keep the token in the Keychain. The token is the session; the code proves
  the number. See section 7, "Sign-in by one-time code".

## 2. Reducers (args are JSON object keys)

App = iOS app acting for its own person. Svc = any service identity (role in brackets when restricted).

| Reducer | Args | Caller |
| --- | --- | --- |
| `request_sign_in` | `phone, name` | App (not services) — texts a code; see section 7 |
| `verify_sign_in` | `phone, code` | App — wrong code still returns 200; read `my_sign_in` |
| `sign_out` | (none) | App — releases the caller's number |
| `register_person` | `phone, name` | Retired: always fails with "use request_sign_in" |
| `ensure_person` | `phone, name` | Svc [photon, agents] |
| `update_settings` | `person_id, accessibility_mode, sharing_paused, critical_overrides_pause, apns_token, family_code_word, tz_offset_minutes` | App, Svc |
| `set_sharing_paused` | `person_id, paused` | App, Svc |
| `upsert_contact` | `person_id, contact_id (0=new), name, phone_e164, relationship, channel, is_emergency_contact` | App, Svc |
| `remove_contact` | `contact_id` | App, Svc |
| `set_contact_consent` | `contact_id, consent_status` (invited/accepted/declined) | Svc [photon, agents] |
| `opt_out_number` | `phone, opt_out (bool)` | Svc, or App for its own number |
| `record_inbound_message` | `photon_message_id, from_e164, channel, body` | Svc [photon] — idempotent |
| `save_message_check` | `request_key, person_id, source, content, model_verdict, reason, campaign_id, sender_e164, link_domains[], similarity_floor, tactics[], evidence_count` | Svc [agents] — applies community floor |
| `add_report_evidence` | `source, channel, sender_e164, links[], claimed_identity, tactics[], text, verdict, campaign_id` | Svc [agents] |
| `report_number` | `person_id, kind (number/link/phrase), value` | App, Svc |
| `open_incident` | `request_key, person_id (0 only for svc), entry_point, caller_e164` | App, Svc |
| `save_answer` | `incident_id, question_id, answer` | App, Svc |
| `set_incident_context` | `incident_id, tactics[], campaign_id` | Svc [agents] |
| `resolve_incident` | `incident_id` | App, Svc |
| `mark_step_done` | `step_id, done` | App, Svc |
| `family_ack` | `incident_id, contact_id` | Svc [photon, agents] |
| `tell_my_family` | `incident_id` | App, Svc |
| `enqueue_outbox` | `to_e164, channel, kind, body, priority, related_incident_id, recipient_contact_id, group_key` | Svc [agents, photon] |
| `mark_outbox_status` | `outbox_id, status, channel ("" = unchanged)` | Svc [photon, agents] |
| `start_verification` | `request_key, person_id, contact_id, kind (relay/trusted_sender)` | App, Svc |
| `resolve_verification` | `verification_id, result (confirmed/denied)` | Svc, or the relative's App |
| `save_briefing` | `person_id, week_start_micros, summary_text, spoken_text` | Svc [agents] — also texts it |
| `request_briefing` | `person_id` | App, Svc |
| `acknowledge_family_alert` | `contact_id` | Svc [photon, agents] — see section 7 |

**Interview answers** (`save_answer`): `q_identity` free text · `q_ask` `yes|no|agreed` (agreed = agreed
to a callback or payment) · `q_shared` comma list of `code,pin,password,card,gift_card,money,remote_app,personal_details,link` or `nothing` ·
`q_secrecy` `yes|no` · `q_help` `yes|no` · optional `q_engaged` `yes|no` (no = declined/blocked) ·
optional `q_summary` free text (redacted call summary). Severity is computed in the module only (D2).

**Outbox field values**: `channel` imessage|sms|rcs|whatsapp|push · `kind` reply|family_alert|checkin|verification|relay|briefing|system ·
`priority` urgent|normal · `status` queued|sending|sent|failed. Family alerts for one incident share
`group_key = family:<person_id>:<incident_id>`. Bodies ≤ 600 chars (briefing ≤ 1200).

## 3. Views (read with SQL)

| View | Who sees rows |
| --- | --- |
| `my_person`, `my_contacts`, `my_incidents`, `my_recovery_steps`, `my_checks`, `my_briefings`, `my_pending_verifications`, `my_alert_requests` | The app identity that owns the person (pending verifications: where the app user is the relative being asked) |
| `my_sign_in` (`phone_e164, attempts_left, last_error, expires_at, created_at`) | The identity with a pending sign-in (never the code or its hash) |
| `caller_labels` (`value, reporter_count`) | Everyone — Call Directory feed |
| `campaign` (table) | Everyone |
| `svc_person`, `svc_contact`, `svc_incident`, `svc_recovery_step`, `svc_message_check`, `svc_community_report`, `svc_report_evidence`, `svc_outbox`, `svc_inbound_message`, `svc_verification`, `svc_alert_request`, `svc_briefing`, `svc_opt_out` | Service identities only (others get zero rows) |

## 4. Agent service HTTP API (`agents/`, default `http://127.0.0.1:8088`)

All `/run/*` and `/push` calls need `Authorization: Bearer {AGENT_SERVICE_TOKEN}`. `/app/*` calls use the
**app's SpacetimeDB token** as bearer; the service resolves the person by querying `my_person` with it.
Every response is JSON validated against `shared/schemas/<workflow>.output.json`. 20 s budget, then a
safe fallback (spec 13). Writes go only through reducers; replies go only through `enqueue_outbox`.

| Endpoint | Body | Returns |
| --- | --- | --- |
| `GET /health` | – | `{"ok": true}` |
| `POST /run/router` | `{text, from_e164, channel, person_id, mode: "text"|"voice"}` | `{intent, args}` — intents: scam_check, advise, command, verify_relative, interview, pause, resume, stop, help, out_of_scope |
| `POST /run/scam_check` | `{person_id, text, sender_e164?, source, reply_to_e164?, reply_channel?, image_base64?}` | `{verdict, reason, campaign_id, tips[], evidence_count}`; queues the reply when `reply_to_e164` is set |
| `POST /run/interview` | `{incident_id, mode: "text"|"app"|"voice", utterance?, checkin?}` | `{next_question?, question_id?, say?, done, severity}` — in voice mode it extracts answers from free speech and saves them |
| `POST /run/family_alert` | `{incident_id, priority}` | `{alerts:[{contact_id, body}]}` |
| `POST /run/verify_relative` | `{person_id, relative_name, claim_from_e164?}` | `{verification_id, messages[]}` |
| `POST /run/trusted_sender` | `{person_id, contact_id, message_text}` | `{verification_id}` (Stretch) |
| `POST /run/briefing` | `{person_id}` | `{summary_text, spoken_text}` |
| `POST /run/command` | `{person_id, text, reply_to_e164?, reply_channel?, args?}` | queues its own reply (section 7) |
| `POST /push` | `{to_e164, title, body, category, verification_id?}` | `{sent: bool}` — APNs delivery for `push` outbox rows |
| `POST /app/check` | `{text, source: "app_paste"|"share"|"screenshot", sender_e164?}` | same as scam_check (no text reply queued) |
| `POST /app/verify` | `{relative_name}` | same as verify_relative |

**Scheduled work uses a task queue, not procedure HTTP.** SpacetimeDB refuses procedure HTTP to
private/loopback addresses, so the module never calls out. Due work (family_alert, interview check-ins,
briefing) becomes an `agent_task` row; the agent service polls `svc_agent_task WHERE status =
'queued'`, calls `claim_agent_task {task_id}`, runs the workflow, then `complete_agent_task {task_id, ok,
error}`. Failure, or no completion within 20 s, marks the task failed; for `family_alert` the module then
queues the template alert (spec 13).

**Interview responses** (all modes) also carry the section 7a result for the described call:
`verdict, reason, evidence_count, campaign_id, alert_sent`. In text mode the agent service queues its own
reply via `enqueue_outbox` (D6); app mode only returns it.

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
iMessage. Inbound: `record_inbound_message`, local text commands, family replies (any reply from an
accepted family member listed on a pending help/alert request → `acknowledge_family_alert`; short "ok /
got it / 👍" replies stop there, free text is also relayed to the family), else `/run/router` (intents
`scam_check`, `advise`, `command` → `/run/command`, `verify_relative`, `interview`, ...).

## 7. Changes (Nov 8, second iteration)

**Removed features.** Practice scams (drills) and the AI voice hotline are gone: no `drill` table,
`schedule_drill`/`record_drill_outcome`, `my_drills`/`svc_drill`, `person.practice_consent`
(`update_settings` and `admin_seed_person` no longer take it), no `practice` workflow, no `voice/`
service, and incident `entry_point` no longer accepts `hotline`. Old evidence rows with
`source = 'hotline'` remain valid data.

**Family replies (help / alert / verify).** Every family notification that needs an answer creates an
`alert_request` row (`my_alert_requests` for the app, `svc_alert_request` for services):

| Field | Meaning |
| --- | --- |
| `kind` | `help` (asked for help during a call), `alert` (High/Critical scam alert), `verify` ("was it really you?") |
| `recipient_contact_ids` | contacts asked; `acked_by_contact_id` who answered |
| `status` | `pending` → `acknowledged`, or `unanswered` after two missed windows |
| `reminders_sent`, `deadline`, `created_at`, `resolved_at` | timing |

- Created automatically: `open_incident(entry_point=companion)` help notices and every `family_alert`
  outbox row with `related_incident_id` + `recipient_contact_id` (kind `alert` when the incident is
  High/Critical, else `help`); `start_verification` creates a `verify` request.
- `family_alert` bodies get " Reply OK so <name> knows you saw this." appended unless they already ask
  for a reply.
- Windows: help 2 min, verify 2 min, Critical 5 min, High 15 min (60 s each with `DEMO_MODE=true`).
  First miss: one urgent reminder to the family + an urgent warning to the person (text + push).
  Second miss: `unanswered` + a final warning naming who to call (verify: verification `expired`).
- Resolving: `acknowledge_family_alert {contact_id}` (photon/agents: any reply from that family member
  — "OK", "got it", "on it", free text) resolves their pending help/alert requests and texts the person
  "<name> saw your alert and replied."; `family_ack` ("I'm calling") resolves that incident's requests;
  `resolve_verification` resolves the verify request.

**Agent service additions.**

| Endpoint | Body | Purpose |
| --- | --- | --- |
| `POST /run/command` | `{person_id, text, reply_to_e164?, reply_channel?, args?}` | iMessage commands understood by Nemotron (report, add/remove/list family, status, code word, briefing, feedback). Queues its own reply. Router intent `command` with `args.action`. |
| `POST /app/feedback` | app token; `{check_id? , request_key?, correct: bool, label?: safe\|suspicious\|likely_scam, note?}` | "Was this right?" from the app; becomes a training label |
| `POST /ios/call-report` | JSON from the iOS Unwanted Communication extension (see below) | Reporting a call from Recents |

**Check ids.** `/run/scam_check` and `/app/check` responses include `check_id` (the stored
`message_check.id`), which `/app/feedback` takes to label that verdict.

**Reporting a call from Recents.** The classification extension cannot use the network, so it returns
an `ILClassificationResponse` whose `userInfo` holds `{token, caller_e164, answers: {q_*: value},
reported_at}`, and iOS POSTs it to `ILClassificationExtensionNetworkReportDestination` =
`<AGENT_SERVICE_URL>/ios/call-report` (HTTPS). The endpoint accepts that object at the top level or
nested (e.g. under `userInfo`), resolves the person from `token` via `my_person`, and with that token
calls `open_incident(report_swipe)`, `save_answer` for each answer, and `report_number`. The extension
also saves the report in the App Group so the app replays it on next launch if the POST never arrived
(idempotent by `request_key`).

**Training log (self-improving Nemotron).** The agent service appends every decision (redacted
input, evidence summary, model verdict, floors, final verdict, workflow) to
`agents/data/training/decisions.jsonl`, and labels to `labels.jsonl` (from iMessage "wrong"/"right",
app feedback, and family outcomes such as a verification denied by the relative). Confirmed examples are
retrieved as few-shot examples at inference, and `agents/scripts/export_training.py` writes a NeMo
Customizer chat-format dataset (`train.jsonl`/`val.jsonl`).

**Forwarded messages (wrapper) and the clarifying question.** iMessage forwarding adds no metadata, so
a text sent to Kavach is the person talking to Kavach unless it is wrapped. The Kavach app (and anyone
typing by hand) marks a forward like this:

```
Forwarded message:
From: +1 555 555 0144
"<the message they received>"
```

- First line: a marker, any case, with or without a colon: `Forwarded message`, `Forwarded`, `Fwd`,
  `Fw`, `Check this`, `Check this message`, `Is this a scam`, `Scam?`. The marker must be followed by
  `:`, `?`, `-`, a newline, an opening quote or the end of the text ("Check this out" is not a marker).
  The forwarded text may also follow on the same line (`Fwd: pay now`).
- Optional next line `From: <name or number>`; a phone number becomes `sender_e164` of the check.
- The forwarded text, in straight or curly quotes or none.
- A marker with nothing after it (`Fwd:`) means "the next text is the forwarded one" (remembered per
  person for 2 minutes). Router returns `{"intent": "clarify", "args": {"reply": "", "reason":
  "await_forward"}}` and nothing is sent. Extra bubbles arriving within 10 s of a forward are checked too,
  unless they read as the person's own question or a command.

Router (`/run/router`, reference parser `agents/kavach/workflows/forward.py`):

1. Wrapped → `scam_check` of the inner text only (`args.text` = inner text, `args.sender_e164` from the
   `From:` line), before any model call and before text commands ("Forwarded message: \"verify Tommy\""
   is checked, not run).
2. Unwrapped → the person's own words by default (`advise`, `command`, `interview`, `verify_relative`,
   `help`). `scam_check` only on deterministic signs of someone else's message: a company/agency prefix or
   alert wording ("USPS: …", "Your account has been locked", "Reply STOP to opt out"), a link, a greeting
   addressed to them plus a request ("Hi Grandpa it's me…"), a sign-off with another name ("Love, Tommy"),
   a verification code. Signals of both kinds, or neither: MODEL_FAST breaks the tie (it may answer
   `ambiguous`); with no sign of someone else's words, a model `scam_check` becomes a question.
3. Genuinely ambiguous → `{"intent": "clarify", "args": {"reply": "Kavach: Is this a message you
   received, or a question for me? Reply 1 if you received it, 2 if it's your question.", "reason":
   "ambiguous"}}`. The text is remembered per person for 10 minutes. `1` / `received` / `message` → 
   `scam_check` of the remembered text; `2` / `question` / `mine` → the right own-voice workflow on it
   (`args.text`, or `args.utterance` for interview). A bare marker also answers "received". Any other text
   drops the remembered one and is routed on its own. With `dispatch: true` the router queues the question
   itself (kind `reply`); otherwise the caller sends `args.reply` when non-empty.
4. A `scam_check` of an unwrapped text carries `args.teach_wrapper: true` at most once a day per person;
   `/run/scam_check` then ends its reply with `Tip: start a forwarded text with "Forwarded message:" so I
   know it's something you received.` The help text always mentions the wrapper.

Follow-up state (bare marker, pending question, tip) lives in the agent service process, keyed by
person, so photon stays stateless; a service restart forgets it. Photon: a wrapped text is never a local
command and never a family "seen it" / relay reply; a bare marker gets no "Checking this now"
acknowledgement; a `1`/`2` reply right after the clarifying question goes to the router even from a
family member; photon passes `args.text`, `args.sender_e164`, `args.teach_wrapper`, `args.args` and
`args.utterance` through to the workflows.

**Sign-in by one-time code (Nov 8, auth).** Replaces `register_person`, which let any device claim an
unclaimed number and refused a number still bound to a signed-out phone ("number already registered").

- Session = a SpacetimeDB identity + token from `POST /v1/identity` (unchanged; works locally and on
  Maincloud). Proof of the number = a 6-digit code texted to it. The phone → identity binding is still
  `person.owner_hex`, so every `my_*` view and access check works as before.
- `request_sign_in {phone, name}`: app identities only. Creates the caller's (single) pending
  `sign_in_challenge` (code stored only as a peppered SHA-256 hash, expires in 10 min) and queues an outbox
  row `kind = system`, `priority = urgent`, `channel = imessage` to `phone`:
  "<APP_DISPLAY_NAME> sign-in code: 123456. Enter it in the <APP_DISPLAY_NAME> app. Never share it with
  anyone, and <APP_DISPLAY_NAME> will never ask you to text it back." Limits: 5 requests per phone and per
  identity per hour, 30 s between codes, and none while the caller's challenge for that phone is locked.
- `verify_sign_in {phone, code}`: correct → the person is created if new, bound to the caller, unbound from
  any other identity (the newest device wins; the old token sees empty `my_*` views and gets "not your
  person"), the caller's previous number (if any) is released, `last_sign_in_at` is set, the challenge is
  deleted. Wrong → **200**, and `my_sign_in.last_error = wrong_code` with `attempts_left`; the 5th wrong code
  sets `too_many_attempts` and locks until expiry. Non-2xx errors: bad input, `no sign-in code was
  requested`, `code expired`, `too many attempts: try again in N min`.
- `sign_out {}`: releases the caller's binding (`owner_hex = ''`, `apns_token = ''`) and pending code.
- Demo: with `DEMO_MODE=true`, numbers starting `+1555555` also accept `000000` and get no text (seeded
  personas can't receive one). Real numbers always need the texted code.
- New columns/tables: `person.last_sign_in_at` (default `[0]`), private `sign_in_challenge` and
  `sign_in_request_log` (cleared by `admin_reset`/`admin_wipe`, purged daily). No view, including `svc_*`,
  exposes a code or hash.
- **For photon/agents:** the sign-in text is an ordinary `system` outbox row; deliver it like any other
  (it is let through opt-outs, like other `system` rows). The code is in clear only while the row is
  queued/sending: `mark_outbox_status` to `sent` or `failed` rewrites it to `sign-in code: [code]`.
  Do not log, echo, summarize or relay outbox bodies of `system` rows containing "sign-in code".
- **Codes are only ever entered in the app.** If someone texts the agent a 6-digit code that matches their
  own pending sign-in code, `record_inbound_message` cancels that sign-in (they must request a new code).
  The agent should never ask for or accept codes; a good reply is "Never share codes, not even with
  <APP_DISPLAY_NAME>. Enter sign-in codes only in the app." Stored check/evidence text is already redacted
  (4–8 digit runs → `[code]`).
- Migration for clients/tests that called `register_person` (e.g. `agents/tests/test_integration.py`):
  `request_sign_in {phone, name}` then `verify_sign_in {phone, code: "000000"}` with a `+1555555xxxx` phone.
  The agent service's "call register_person first" errors should now say "sign in in the app first".
- Later: move to OIDC (SpacetimeAuth, or an SMS-OTP provider such as Auth0/Clerk/Twilio Verify issuing
  JWTs). SpacetimeDB validates the JWT on connect, `ctx.sender` becomes the identity derived from
  `iss`+`sub`, and reducers can read the phone claim from `ctx.senderAuth.jwt`; `request_sign_in`/
  `verify_sign_in` would then collapse into "bind the verified `phone_number` claim".
