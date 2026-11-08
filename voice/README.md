# voice — the Kavach scam hotline (Pipecat)

Anyone calls the hotline number, describes what happened, and hears a verdict, the risk level and
the first steps. Inbound calls only: this service never places a call (spec 10, 12).

```
Twilio number ──webhook──▶ POST /twilio/voice  → TwiML <Connect><Stream wss://…/ws>
              ──media────▶ WS /ws → Pipecat: transport → Silero VAD → STT → HotlineProcessor → TTS → transport
                                                               │
                                       HotlineSession ─────────┤ /run/router, /run/interview (mode voice)  → agents/
                                                               └ open_incident, save_answer(q_summary),
                                                                 tell_my_family, add_report_evidence      → SpacetimeDB
```

| File | What it is |
| --- | --- |
| `hotline.py` | `HotlineSession`, the transport-independent conversation (greeting, interview, verdict, family, repeat, fallbacks) |
| `pipeline.py` | Pipecat 1.15 pipeline, provider selection, `HotlineProcessor` (frames ⇄ session, barge-in, DTMF) |
| `server.py` | FastAPI: `/health`, Twilio webhook (TwiML), media-stream websocket |
| `simulate.py` | Text REPL that drives `HotlineSession` exactly like the pipeline (demo rehearsal, no telephony) |
| `redact.py` | Masks codes, PINs, card/account/phone numbers (digits and spoken digits) before anything leaves the process |
| `stdb.py`, `agent_client.py` | SpacetimeDB HTTP client (voice identity) and agent-service client |
| `tests/stub_agent.py` | Stub agent service (`/run/router`, `/run/interview`) that saves answers on the real DB |

## Setup

```bash
cd voice
uv sync                      # Python 3.12 venv with pipecat-ai[deepgram,cartesia,silero,websocket]
```

Config comes from the repo-root `.env` (never overridden; real env vars win):

| Key | Use |
| --- | --- |
| `APP_DISPLAY_NAME` | Spoken name: "Hi, this is <name>…" |
| `SPACETIME_URI`, `SPACETIME_DB_NAME` | SpacetimeDB; token from `SPACETIME_TOKEN_VOICE` or root `.spacetime-tokens.json` (`voice`) |
| `AGENT_SERVICE_URL`, `AGENT_SERVICE_TOKEN` | Agent service (`/run/router`, `/run/interview`) |
| `TELEPHONY_PROVIDER` | `twilio` (default), `telnyx`, `plivo` |
| `TELEPHONY_ACCOUNT_SID`, `TELEPHONY_AUTH_TOKEN` | Twilio account SID + auth token (webhook signature check, hang-up at goodbye) |
| `STT_PROVIDER` / `TTS_PROVIDER` | `deepgram` (default STT) or `cartesia`; `cartesia` (default TTS) or `deepgram` |
| `DEEPGRAM_API_KEY`, `CARTESIA_API_KEY` | Service keys; optional `CARTESIA_VOICE_ID`, `DEEPGRAM_TTS_VOICE`, `DEEPGRAM_STT_MODEL` |
| `TTS_SPEED` | Default `0.9` (≈140 words per minute) |
| `VOICE_PORT` | Default `8765` |
| `VOICE_PUBLIC_URL` | Public https base, e.g. `https://abc.ngrok.app` (TwiML stream URL and signature check) |
| `VOICE_STREAM_SECRET` | Optional; signs caller ID handed from webhook to stream (random per process if unset) |
| `VOICE_AGENT_TIMEOUT_S` (20), `VOICE_FILLER_AFTER_S` (0.7), `VOICE_FAMILY_ALERT_WAIT_S` (4) | Agent budget, "One moment" filler, wait for family-alert rows |
| `TWILIO_VALIDATE_SIGNATURE` | `false` to skip `X-Twilio-Signature` checking (local testing only) |

### Twilio

1. Buy a voice-capable number (Console → Phone Numbers).
2. Run the service and expose it: `uv run python server.py` and `ngrok http 8765`.
3. Set `VOICE_PUBLIC_URL=https://<ngrok-host>` in `.env` and restart.
4. Number → Voice configuration → "A call comes in": Webhook, `POST https://<ngrok-host>/twilio/voice`.
5. Call the number. `GET /health` shows which keys are configured.

The webhook verifies `X-Twilio-Signature` when `TELEPHONY_AUTH_TOKEN` is set, rejects non-inbound
calls, and passes `From` to the stream with an HMAC so a stray websocket client cannot claim to be a
registered caller (unsigned streams are treated as unknown callers).

## Run

```bash
uv run python server.py                         # hotline on :8765
uv run python simulate.py                       # rehearse by typing; uses SPACETIME_DB_NAME + AGENT_SERVICE_URL
uv run python simulate.py --stub                # …with the stub agent on :8097
uv run python simulate.py --caller ''           # withheld / unknown caller
```

In the simulator, each line is what the caller says, `#1` presses 1, `/hangup` ends the call.

## Tests

```bash
# one-time: own database whose module calls the stub agent (repo root)
set -a; . ./.env; set +a; export SPACETIME_DB_NAME=kavach-voice AGENT_SERVICE_URL=http://127.0.0.1:8097
(cd spacetime && spacetime publish kavach-voice -s local -y --delete-data=always)
npx tsx scripts/service_tokens.ts >/dev/null; npx tsx scripts/demo_reset.ts

cd voice && uv run pytest -q
```

`tests/test_integration.py` resets `kavach-voice`, starts the stub agent and runs real calls through
`HotlineSession` (skipped when SpacetimeDB is down). `tests/test_ws.py` runs the real FastAPI
websocket, Pipecat transport and Twilio serializer with fake STT/TTS.

## Call flow (spec 10)

1. Greeting with `APP_DISPLAY_NAME`, then "Please don't tell me any codes, PINs, card numbers or account numbers."
2. Caller ID → `svc_person` (unknown or withheld callers allowed); `open_incident` (`entry_point=hotline`,
   `person_id` 0 for unknown callers) runs while the greeting plays.
3. The free description is redacted and saved as `q_summary` (before severity can rise, so the module's
   community evidence row carries the script), then sent to `/run/router` (advisory: off-topic check)
   and `/run/interview` (`mode: "voice"`) each turn until `done`. Severity is only ever read from SpacetimeDB.
4. Verdict, level, "many people have reported this number" (exact caller-number match, 3+ reporters),
   and the first two vetted recovery steps from `shared/recovery_library.yaml`.
5. Critical: offer to stay on the line (stays quiet while the caller talks to their bank, until "I'm back").
6. "I've told your family." only when `family_alert` outbox rows exist for the incident; Medium with a
   registered caller: "Would you like me to tell your family?" (yes → `tell_my_family`).
7. After every answer: "Press 1 or say repeat." Keypad 1 or "repeat" replays the last answer.
8. Agent slow → "One moment while I check." at 0.7 s; no answer in 20 s → spoken safe fallback.
9. At the end or on hang-up: add the redacted script to the corpus with `add_report_evidence` if neither the
   module nor the agent service did (looked like a scam but severity never rose, or no row exists).

Privacy: no audio or transcript is stored; only the redacted summary on the incident. Deepgram also
redacts `pci`, `ssn` and `numbers` at the source. Logs are JSON with event names, ids, latencies
(`first_audio_ms`, `over_target` against the 1.5 s target) and outcomes — never caller content.
