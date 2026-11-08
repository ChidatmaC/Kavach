# Kavach agent service (`agents/`)

Python 3.12 + FastAPI, workflows hosted on **NVIDIA NeMo Agent Toolkit** (`nvidia-nat` 1.9), rails on
**NeMo Guardrails** (0.24), Nemotron through the hosted NIM API. Implements docs/CONTRACTS.md section 4.
The product name always comes from `APP_DISPLAY_NAME`.

## Run

```bash
cd agents
uv sync                                    # Python 3.12 venv + deps (uv.lock)
uv run uvicorn server:app --host 127.0.0.1 --port 8088
```

Config comes from the environment, then the repo-root `.env`. The service token for SpacetimeDB is
`SPACETIME_TOKEN_AGENTS` or the `agents` entry in `.spacetime-tokens.json`.

Without `NIM_API_KEY`, every workflow runs its deterministic no-model path (heuristic classifier, lexical
similarity, template wording). With a key, it uses `MODEL_FAST` for routing, classification and extraction,
`MODEL_WRITER` for text people read, and `MODEL_EMBED` for similarity. Optional extras: `MODEL_VISION`
(screenshot text recognition for `image_base64`), `APNS_SANDBOX=false` (production APNs),
`KAVACH_USE_NAT=false` and `KAVACH_USE_GUARDRAILS=false` (plain-Python seams), `AGENT_RUN_TIMEOUT_S` (20).

**Scheduled work (agent task queue).** The module no longer calls this service over HTTP (SpacetimeDB refuses
private addresses). Due jobs become `agent_task` rows. A background poller in `server.py` (`kavach/tasks.py`)
runs every 500 ms with at most 4 tasks in flight:
1. read `svc_agent_task WHERE status = 'queued'`;
2. `claim_agent_task` (a refusal means another poller has it);
3. run the same schema-checked workflow function `/run/{workflow}` uses, with an 18 s budget;
4. `complete_agent_task(ok, error)`.
The module fails a task after 20 s or on `ok=false`, and for family_alert queues its template alert.
`AGENT_TASK_POLLER=false` disables the poller. `POST /tasks/poller {"enabled": false|true}` (service bearer)
pauses or resumes claiming at runtime.

`GET /health` returns `{"ok": true}`. `GET /health/details` shows the engine (`nat`/`python`), guardrails
engine, whether the LLM is on, and the database name.

## Tests

```bash
uv run pytest -m "not integration"         # unit tests, no services needed

# integration: own database, seeded, service running
cd .. && set -a && . ./.env && set +a
export SPACETIME_DB_NAME=kavach-agents AGENT_SERVICE_URL=http://127.0.0.1:8088
(cd spacetime && spacetime publish kavach-agents -s local -y --delete-data=always)
npx tsx scripts/service_tokens.ts >/dev/null && npx tsx scripts/demo_reset.ts
cd agents && uv run uvicorn server:app --port 8088 &   # same shell, so SPACETIME_DB_NAME applies
uv run pytest -m integration -v                       # resets the demo data itself
```

## Layout

```
server.py                 FastAPI app: auth, input/output schema checks, 20 s budget, fallbacks, /push, /app/*
configs/<workflow>.yml    one NAT config per workflow (llms: nemotron_fast / nemotron_writer, embedder, tools)
guardrails/               NeMo Guardrails config.yml + rails.co (input scope rail, output safety + practice rails)
kavach/
  tasks.py                agent_task poller: claim -> run workflow -> complete (bounded concurrency)
  engine.py               loads the 8 NAT workflows at startup; falls back to plain Python if NAT fails
  nat_plugin.py           NAT registrations: kavach_tool (shared tools) and kavach_<workflow>
  tools.py                shared tools, the 6-call budget, per-workflow reducer allowlist
  stdb.py                 SpacetimeDB HTTP client (svc_* reads, reducer writes, request_key read-back)
  community.py            search_community / lookup_community / local community floor (spec 7a)
  similarity.py           NIM embeddings (cached) with a pure-Python lexical fallback
  signals.py              URL/number/identity/tactic extraction and check_link heuristics
  guard.py                Guardrails seam (rails call deterministic Python actions)
  llm.py                  NIM client: schema-checked JSON steps, retry once, then None -> fallback
  redact.py, recovery.py, schemas.py, apns.py, log.py, config.py
  workflows/              router, scam_check, interview, family_alert, verify (+trusted_sender), briefing (+practice)
tests/                    unit + integration tests
../shared/schemas/        JSON Schemas: <workflow>.input/.output, model steps, outbox_row
../shared/prompts/        one prompt file per workflow
```

## Behavior notes for other components

- **router** classifies only by default and returns `{intent, args}`, where `args` is the ready-to-send body
  for `/run/<intent>`. `help` and `out_of_scope` carry `args.reply`; `pause`/`resume`/`stop` carry the reducer
  args for the caller. Send `"dispatch": true` to have the router also run scam_check, verify_relative or
  interview and return `result` (it then also queues the help/out-of-scope reply). Voice: `mode: "voice"`.
- **interview**, text mode: the service queues the next question or check-in itself (`enqueue_outbox`).
  In app and voice modes it only returns them. Every response also includes `verdict`, `reason`,
  `evidence_count`, `campaign_id` and `alert_sent`, from search_community on the described call script and
  caller number. `free_text: true` (set by the router for a first description) extracts all five answers.
- `/run/{workflow}` stays for photon-worker, voice and the app. Scheduled jobs (family_alert, interview
  check-ins, briefing, practice) arrive through the task queue instead.
- **family_alert** pre-filters with the `canAlertContact` rules; reducer refusals are expected and are
  logged, not retried. If nothing could be queued for an unexpected reason (or the run times out), it
  fails, so the module queues its template alert (HTTP: 5xx; task: `complete_agent_task ok=false`).
- **/push**: `verification_id` is optional. If it's missing, the service uses the newest pending
  `trusted_sender` verification for that recipient, and sets category `TRUSTED_SENDER`. Without APNs keys
  or a device token it logs and returns `{"sent": false}`.
- Logs are JSON lines with workflow, ids, latency, outcome, tool-call count and verdicts. Never message contents.
