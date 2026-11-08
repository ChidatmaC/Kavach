# Kavach

Kavach turns every scam report into a live warning that protects the reporter's family: an AI agent you
can text or call, alerts that reach every chosen family contact, and an iPhone app for checking things and
following up. Detection is a community-informed search over shared scam reports combined with Nemotron
analysis (spec section 7a); the reports themselves stay internal.

- Spec: [`ScamShield Mesh Build Requirements for Claude Code.md`](ScamShield%20Mesh%20Build%20Requirements%20for%20Claude%20Code.md) (product renamed Kavach via `APP_DISPLAY_NAME`)
- Wire contracts: [`docs/CONTRACTS.md`](docs/CONTRACTS.md)

| Component | Stack | What it does |
| --- | --- | --- |
| `spacetime/` | SpacetimeDB 2.14 TypeScript module | All state, reducers, rule-based severity, community verdict floor, schedules, agent task queue, access views |
| `agents/` | Python, NeMo Agent Toolkit 1.9, NeMo Guardrails 0.24, NIM | All workflows; `search_community`; `/run/*`, `/app/*`, `/push`; polls `agent_task` |
| `photon-worker/` | TypeScript, `spectrum-ts` | iMessage/SMS in and out; text commands; outbox delivery with retries, SMS fallback, family groups |
| `voice/` | Python, Pipecat 1.15 (Twilio, Deepgram, Cartesia) | The inbound scam hotline |
| `ios/` | SwiftUI, iOS 26, XcodeGen | Six screens + interview, four extensions, App Intents, push |

## Run locally

Full instructions for a fresh Mac are in [`SETUP.md`](SETUP.md). The short version, once tools are installed:

```sh
spacetime start                         # separate terminal
cp .env.example .env                    # set SERVICE_CLAIM_KEY, AGENT_SERVICE_TOKEN, NIM_API_KEY
npm install && (cd spacetime && npm install) && (cd photon-worker && npm install)
(cd agents && uv sync) && (cd voice && uv sync)
npm run publish:local:clean && npm run tokens && npm run demo:reset
npm run start:local                     # agent service + iMessage worker (console)
scripts/text.sh +15555550101 "verify Tommy"
cd ios && xcodegen generate && open Kavach.xcodeproj   # then ⌘R, sign up as Joe +15555550101
```

Without `NIM_API_KEY`, every workflow runs on deterministic fallbacks (heuristics plus community search
with lexical similarity), which is enough to rehearse the whole demo.

## Test status

| Suite | Result |
| --- | --- |
| Module smoke (`npm run smoke`) | 28/28 |
| agents unit / integration | 88 passed (1 skipped) / 14 passed |
| photon-worker | 88 passed, typecheck clean |
| voice | 39 passed |
| iOS | simulator build succeeds; 27 XCTests passed (live against SpacetimeDB) |

Verified across components on one database: forwarded toll text → "Likely scam" reply; "verify Tommy" → Tommy
replies "not me" → Joe warned and family told; hotline gift-card call → Critical, spoken verdict and steps,
explained family alerts via the agent task queue; template alerts after 20 s when the agent service is down.

## Not yet verified (needs credentials or devices)

- Real NIM calls (model ids, embeddings): no `NIM_API_KEY` was available.
- A real Photon line (iMessage groups, SMS fallback), a real phone call through Twilio/Deepgram/Cartesia, APNs.
- On-device: Call Directory labels, the Report extension in Recents on iOS 26, Action Button, CallKit end-of-call, Face ID push actions.
- Phone numbers are not SMS-verified at registration (MVP).
