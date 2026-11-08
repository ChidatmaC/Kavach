# photon-worker

The only process that sends or receives texts (spec section 9, D5, D6). It takes inbound messages to
SpacetimeDB and the agent service, and delivers every `outbox` row.

```
inbound text --> record_inbound_message --> local command? --> reducers + reply via enqueue_outbox
                                          \-> family-thread reply? --> relay rows to other members
                                          \-> POST /run/router --> scam_check | verify_relative | interview | ...
svc_outbox (queued, polled every 500 ms) --> sending --> Photon / console --> sent | retry | SMS | failed
                                                   \-> push rows --> agent service POST /push
```

## Run

Node 20+. Config comes from the repo-root `.env`; the SpacetimeDB token from `SPACETIME_TOKEN_PHOTON` or
the root `.spacetime-tokens.json` (`npm run tokens` at the root).

```sh
cd photon-worker
npm install
npm run dev          # MESSAGING_GATEWAY=console by default
npm test             # unit + integration (integration needs local SpacetimeDB, see below)
npm run test:unit    # no network needed
npm run typecheck
```

Console gateway: type a sender, `>`, and the text. Outbound messages print as `[channel -> number] body`.

```
+15555550101> verify Tommy
+15555550102> not me
+15555550103:sms> stop
+15555550101> /img ./toll.png is this real?
/fail +15555550102 2          # make the next 2 sends to that number fail (watch retries)
```

Real iMessage line: set `MESSAGING_GATEWAY=photon`, `PHOTON_PROJECT_ID`, `PHOTON_API_KEY` (the Spectrum
project secret) and `PHOTON_AGENT_LINE` (the dedicated line's E.164 number).

| Env | Default | Meaning |
| --- | --- | --- |
| `MESSAGING_GATEWAY` | `console` | `console` or `photon` |
| `SPACETIME_URI`, `SPACETIME_DB_NAME` | `http://127.0.0.1:3000`, `kavach` | database |
| `AGENT_SERVICE_URL`, `AGENT_SERVICE_TOKEN` | `http://127.0.0.1:8088` | agent service |
| `AGENT_TIMEOUT_MS` | `20000` | per agent call, then the fallback reply |
| `PHOTON_HEALTH_PORT` | `8090` | `GET /health` |
| `OUTBOX_POLL_MS` | `500` | outbox poll interval |
| `FAMILY_REPLY_WINDOW_MINUTES` | `60` | a contact's free text counts as a family-thread reply this long after we last texted them |
| `APP_LINK_DOMAINS` | – | extra domains allowed as tappable links (the app's site) |
| `APP_DISPLAY_NAME` | `Kavach` | product name in every message |

`GET http://127.0.0.1:8090/health` returns `{"ok": true, "gateway": ..., "sent": n, "failed": n, ...}`;
`ok` is false (503) when the outbox poll has stalled.

## Integration tests

They run against their own database, `kavach-photon` (override with `INTEGRATION_DB`; they refuse to
run against `kavach`), reset it with `scripts/demo_reset.ts`, and start a stub agent service on port
8099 (or any free port). One-time setup from the repo root:

```sh
set -a; . ./.env; set +a; export SPACETIME_DB_NAME=kavach-photon AGENT_SERVICE_URL=http://127.0.0.1:8099
(cd spacetime && spacetime publish kavach-photon -s local -y --delete-data=always)
npx tsx scripts/service_tokens.ts >/dev/null
```

## Behavior

**Inbound** (`src/inbound.ts`)
1. Dedupe on the provider message id (in memory, then `svc_inbound_message`), then `record_inbound_message`.
2. Look up the sender as a person and as family contact rows.
3. Local commands (`src/commands.ts`, whole-message match, case-insensitive):
   `verify <name>` (person -> `/run/verify_relative`), `yes / it's me / confirmed` and `no / not me`
   (contact with a pending verification -> `resolve_verification`), `I'm calling / on it` (contact ->
   `family_ack` on the person's latest open High/Critical incident), `pause / resume` (person),
   `stop` / `start` (anyone -> `opt_out_number`), `help`, `join <name>` (invited contact ->
   `set_contact_consent accepted`). A command that doesn't apply to the sender falls through.
4. Images skip the router: `/run/scam_check` with `image_base64` and `source: "screenshot"`.
5. A free-text reply from an accepted contact we texted within the window (family alert, relay,
   verification, check-in) is relayed to the other accepted contacts as `relay` rows, `"<Name>: text"`.
   In a group thread nothing is relayed (everyone saw it).
6. Everything else: `ensure_person` for unknown texters, `POST /run/router`, then dispatch on intent.
   `scam_check` passes `reply_to_e164` so the agent queues the verdict. If the router fails, the
   text is sent to `scam_check`; if that fails, the spec's fallback reply is queued.
   Opted-out numbers are ignored except for `start`/`stop`.

**Outbound** (`src/outbox.ts`)
- Poll `svc_outbox WHERE status = 'queued'`; urgent first, then oldest, then lowest id.
- Before each send: skip ids in flight or already delivered, re-read the row and skip it unless still
  `queued`, refuse opted-out numbers (except `system` rows, as the module does) by marking `failed`.
- Set `sending`, deliver, set `sent` (with the channel actually used if it changed).
- Failure: back to `queued` behind a retry gate of 5 s, 15 s, 45 s; after the 4th failed iMessage
  attempt the row is switched to `sms` once; if that fails, `failed`. SMS/RCS/push rows fail after 3 retries.
- Rows sharing a `group_key` go out as one iMessage group when the gateway supports groups, there are
  2+ recipients, every row is `imessage` (and live reachability doesn't say otherwise) and the text is
  identical. Otherwise each goes individually on its own channel. A failed group send retries individually.
- `push` rows -> agent service `POST /push {to_e164, title, body, category}`.
- On start, rows left in `sending` by a crash are requeued (at-least-once).
- Message style: links other than official sites (ftc.gov, reportfraud.ftc.gov, identitytheft.gov, ...)
  and `APP_LINK_DOMAINS` are defanged (`txtag-pay[.]top`), at most 2 links, 600 chars (briefing 1200).

**Logs**: one JSON object per line on stderr, with event name, ids, outcome and latency. No message
text, and phone numbers are masked to the last 4 digits.

## spectrum-ts notes (v12.15)

- `Spectrum({ projectId, projectSecret, providers: [imessage.config()] })` connects to Spectrum Cloud;
  `app.messages` yields `[space, message]`; `message.sender.service` is `iMessage | SMS | RCS`.
- `imessage(app).space.create(numbers, { phone: line })` makes a DM (1 number) or a group (2+).
  Groups need a dedicated line; the SDK's shared mode throws `UnsupportedError` for groups.
- The SDK has no "send as SMS" switch. DMs are `any;-;<number>`, which lets Messages pick the service.
  For the explicit SMS fallback we address `SMS;-;<number>` (Apple's SMS chat guid).
- Live iMessage reachability comes from the Advanced iMessage client's
  `addresses.isIMessageAvailable` (reached through `app.__internal`; cached 10 minutes).
- Not exercised against a real line (no credentials): group creation, the `SMS;-;` fallback,
  reachability lookups, and inbound attachment download.
- The spectrum-ts terminal provider downloads a separate TUI binary and models one chat, so the
  console gateway uses readline instead.
