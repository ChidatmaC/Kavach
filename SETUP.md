# Setting up Kavach on a new Mac

This gets the full stack running locally: SpacetimeDB, the agent service (Nemotron via NVIDIA NIM), the
iMessage/SMS worker in console mode, the voice hotline simulator, and the iPhone app in the Simulator.
It takes about 20 minutes, most of it installs.

Versions this was built and tested with are in brackets.

## 1. Install the tools

You need macOS on Apple silicon with **Xcode 26** [26.4.1] from the App Store. Open Xcode once to accept
the license and install the iOS 26 Simulator (Xcode → Settings → Components).

```sh
# Homebrew (skip if you have it): https://brew.sh
brew install uv xcodegen git            # uv [0.13], xcodegen [2.46]

# Node 22 [22.13] via nvm (or any Node 20+)
brew install nvm && mkdir -p ~/.nvm
# follow the two lines nvm prints for your shell profile, open a new terminal, then:
nvm install 22

# SpacetimeDB CLI + local server [2.14.1]
curl -sSf https://install.spacetimedb.com | sh
# open a new terminal, then pin the version the module was built against:
spacetime version install 2.14.1 && spacetime version use 2.14.1
spacetime --version
```

`uv` downloads Python 3.12 for the Python services by itself; you don't need to install Python.

## 2. Clone and configure

```sh
git clone <your-repo-url> kavach && cd kavach
cp .env.example .env
```

Edit `.env` and set these (everything else can stay as is):

| Key | Value |
| --- | --- |
| `SERVICE_CLAIM_KEY` | any random string, e.g. output of `openssl rand -hex 24` |
| `AGENT_SERVICE_TOKEN` | another random string, e.g. `openssl rand -hex 24` |
| `NIM_API_KEY` | an NVIDIA API key (`nvapi-...`) from [build.nvidia.com](https://build.nvidia.com). Optional: without it every workflow uses rule-based fallbacks |

The model ids in `.env.example` (`MODEL_FAST`, `MODEL_WRITER`, `MODEL_EMBED`, `MODEL_VISION`) were
checked against one NVIDIA account. Model availability differs per account, so check yours:

```sh
curl -s -H "Authorization: Bearer $NIM_API_KEY" https://integrate.api.nvidia.com/v1/models \
  | python3 -c "import json,sys; [print(m['id']) for m in json.load(sys.stdin)['data'] if 'nemotron' in m['id']]"
```

Never commit `.env` or `.spacetime-tokens.json`; both are in `.gitignore`.

## 3. Install dependencies

```sh
npm install                                   # root scripts (seed, tokens, smoke)
(cd spacetime && npm install)                 # SpacetimeDB module
(cd photon-worker && npm install)             # iMessage/SMS worker
(cd agents && uv sync)                        # agent service (NeMo Agent Toolkit, Guardrails)
(cd voice && uv sync)                         # voice hotline (Pipecat)
```

## 4. Start SpacetimeDB and load the demo data

In a **separate terminal**, leave this running:

```sh
spacetime start
```

Then, from the repo root:

```sh
npm run publish:local:clean   # publish the module as database `kavach`
npm run tokens                # one SpacetimeDB identity per service -> .spacetime-tokens.json
npm run demo:reset            # load shared/seed/demo.json (Joe, Tommy, Maria, campaigns, reports)
npm run smoke                 # expect "All checks passed" (28 checks)
```

`npm run smoke` wipes and re-seeds the database, so run `npm run demo:reset` again afterwards if you like.

## 5. Start the services

```sh
npm run start:local
```

This starts the agent service on `:8088` and the iMessage worker (console mode) on `:8090`, logging to
`.run/agents.log` and `.run/photon.log`. Stop them with `npm run stop:local`.

Text the agent as any number and see its replies:

```sh
scripts/text.sh +15555550101 "TxTag: unpaid toll \$6.80, pay now https://txtag-pay.top/inv/1"
scripts/text.sh +15555550101 "verify Tommy"
scripts/text.sh +15555550102 "not me"          # Tommy answers the verification
```

Demo people: **Joe** `+15555550101` (protected person), **Tommy** `+15555550102` (grandson, iMessage,
emergency contact), **Maria** `+15555550103` (daughter, SMS). Family code word: "blue pancake".

## 6. Run the iPhone app

```sh
cd ios && xcodegen generate && open Kavach.xcodeproj
```

In Xcode pick the **Kavach** scheme and an **iPhone 17** simulator, then press **⌘R**. No signing is
needed for the Simulator. In the app, sign up as **Joe** with **+15555550101** to see the demo data.

If the app says the number is already registered (e.g. after an earlier test run), free it with
`npm run dev:wipe` and sign up again.

Ways to feed the app a "message" (the app can't read real SMS; see the spec's platform constraints):
- `scripts/text.sh +15555550101 "..."`: the check then shows in the app under **This week**.
- `echo "some text" | xcrun simctl pbcopy booted`, then tap **Paste** on Check a message.
- Share text from Notes in the Simulator to **Kavach** (Share extension).
- Test a push banner:
  ```sh
  printf '{"Simulator Target Bundle":"com.kavach.app","aps":{"alert":{"title":"Kavach","body":"Tommy says it was NOT them. This is a scam."}}}' > /tmp/kavach.apns
  xcrun simctl push booted com.kavach.app /tmp/kavach.apns
  ```

## 7. Try the voice hotline (no phone line needed)

```sh
cd voice && uv run python simulate.py --caller +15555550101
```

Type what the caller says (for example, describe a "grandson in jail" call where you bought gift cards).
`#1` presses keypad 1, `/hangup` ends the call. A real phone line needs Twilio, Deepgram and Cartesia keys;
see `voice/README.md`.

## 8. Run the tests

| Component | Command |
| --- | --- |
| SpacetimeDB module | `npm run smoke` |
| agents (unit) | `cd agents && uv run pytest -m "not integration"` |
| agents (integration) | see `agents/README.md` (uses its own database, `kavach-agents`) |
| photon-worker | `cd photon-worker && npm test` |
| voice | `cd voice && uv run pytest` |
| iOS | `cd ios && xcodebuild test -scheme Kavach -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO` |

## Running on a real iPhone

See `ios/README.md` for details. Put your settings in `ios/Config/Local.xcconfig` (gitignored), not in
Xcode, because `xcodegen generate` rewrites the project:

```
DEVELOPMENT_TEAM = <your Apple team id>
SPACETIME_URL = https:/$()/<spacetimedb address>
AGENT_SERVICE_URL = https:/$()/<agent service address>
```

The bundle ids are `com.hack.kavach.app` (+ `.CallDirectory`, `.Report`, `.Share`, `.MessageFilter`). If
your team can't use them, change the prefix everywhere in `ios/` (project.yml, entitlements, App Group in
`Config/Kavach.xcconfig`, `AppModel.swift`, `SharedStore.swift`, `AppConfig.swift`) and `APNS_TOPIC` in
`.env`; extension ids must start with the app's id.

**Reaching the backend from the phone.** `127.0.0.1` on a phone is the phone itself. Two options:

- **Tunnels (works on any network, recommended):** `brew install cloudflared`, then
  `cloudflared tunnel --url http://127.0.0.1:3000` and `cloudflared tunnel --url http://127.0.0.1:8088`
  in two terminals. Use the two `https://….trycloudflare.com` addresses they print as `SPACETIME_URL` and
  `AGENT_SERVICE_URL`. The addresses change every time the tunnels restart, and anyone with them can
  reach your dev backend while they run.
- **Same Wi-Fi:** start SpacetimeDB with `spacetime start --listen-addr 0.0.0.0:3000` and use
  `http:/$()/<Mac IP>:3000` / `:8088` (`ipconfig getifaddr en0`). Fails on hotspots and on campus or venue
  Wi-Fi that blocks device-to-device traffic.

**Push notifications** need an APNs key (paid Apple Developer account): set `APNS_KEY_ID`,
`APNS_TEAM_ID` and `APNS_KEY_P8` (path to the `.p8` file) in `.env`, then restart the services. Xcode
builds use Apple's sandbox push server, which is the default.

Caller labels, the Recents report extension, the Action Button and push notifications only work on a
device.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `SpacetimeDB is not running` | Run `spacetime start` in another terminal. |
| `no token for admin; run "npm run tokens"` | Run `npm run tokens` (after every `publish:local:clean`). |
| `register_person: 530 number already registered` | `npm run dev:wipe` frees app sign-ups and re-seeds. |
| Replies are generic / say they couldn't check | `NIM_API_KEY` missing, or a model id isn't enabled for your account (see step 2). Check `.run/agents.log`. |
| `Address already in use` on 8088/8090 | `npm run stop:local`, then start again. |
| Publish fails with a schema error | `npm run publish:local:clean` (drops local data), then `npm run tokens && npm run demo:reset`. |
| App shows no data | Make sure you signed up as `+15555550101` and `npm run start:local` is running. |
