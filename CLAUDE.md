# Kavach

Spec: `ScamShield Mesh Build Requirements for Claude Code.md` (product renamed Kavach; the name lives only in `APP_DISPLAY_NAME`).
Wire contracts between components: `docs/CONTRACTS.md`. The SpacetimeDB module (`spacetime/src/`) is the source of truth.

## Run (local)
- `spacetime start` (local server on :3000), then from repo root: `cp .env.example .env` and fill `SERVICE_CLAIM_KEY`, `AGENT_SERVICE_TOKEN`.
- `npm install && npm run publish:local:clean && npm run tokens && npm run demo:reset && npm run start:local` (full steps: `SETUP.md`)
- `npm run smoke` — 28 end-to-end checks (wipes and re-seeds first) of the module (access rules, severity, pause/override, community floor, verification, labels).
- Component READMEs: `agents/`, `photon-worker/`, `voice/`, `ios/`.

## Rules that are easy to break
- Wire names are exact snake_case (module uses `CaseConversionPolicy.None`); reducer/view exports are snake_case.
- Severity (D2) and the community verdict floor (D14, section 7a) are computed only in the module; agents never lower them.
- Community reports are service-only (D15): read via `svc_*` views; apps see only `caller_labels`.
- All outgoing messages go through `enqueue_outbox` (D6). Reducers never do network I/O; `run_agent_job` is the only procedure that calls out.
