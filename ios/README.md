# Kavach iOS app

Thin SwiftUI client (spec section 11) plus four extensions. It talks to SpacetimeDB over its HTTP API
(reducers + `my_*` / `caller_labels` / `campaign` reads, polled every 3 s while open) and to the agent
service via `/app/check` and `/app/verify`, using the app's own SpacetimeDB token as the bearer. No
business logic lives here: severity, alerts and floors are all in the module.

## Layout

| Path | What |
| --- | --- |
| `project.yml` | XcodeGen spec → `Kavach.xcodeproj` |
| `Config/Kavach.xcconfig` | `APP_DISPLAY_NAME`, backend URLs, DB name, App Group. The only place the name lives |
| `KavachKit/` | Shared framework: API clients, models, SQL decoding, interview, verdict badge, theme, speech, OCR |
| `App/` | The app: Home, Check a message, Call Companion, Interview, Act now, Family, Settings, onboarding, App Intents, push |
| `CallDirectoryExtension/` | Caller labels "Likely scam: N reports" from the App Group cache |
| `ReportExtension/` | Unwanted Communication (report from Recents) hosting the shared interview |
| `ShareExtension/` | Shared text, links or screenshots → `/app/check`, verdict in the sheet |
| `MessageFilterExtension/` | Stretch: unknown senders with a community label → Junk |
| `Tests/KavachTests/` | XCTest: SQL decoding, interview encoding, Accessibility Mode, live API tests |

The vetted recovery-step wording is copied from `../shared/recovery_library.yaml` into KavachKit at build
time (it is a resource of the framework target), so the app always shows the library's exact text.

## Build and test

```sh
brew install xcodegen          # once
cd ios
xcodegen generate
xcodebuild -scheme Kavach -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
# Unit + live API tests (need SpacetimeDB on :3000 with a seeded `kavach-ios` database; skipped otherwise):
xcodebuild test -scheme Kavach -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

To prepare the test database (from the repo root):

```sh
set -a; . ./.env; set +a; export SPACETIME_DB_NAME=kavach-ios
(cd spacetime && spacetime publish kavach-ios -s local -y --delete-data=always)
npx tsx scripts/service_tokens.ts >/dev/null; npx tsx scripts/demo_reset.ts
```

Open `Kavach.xcodeproj` in Xcode to run on a device. `Kavach.xcodeproj` is generated; edit `project.yml`.

## Point the app at your backend

The Simulator reaches the Mac as `127.0.0.1`, so the defaults work there. A real iPhone needs the Mac's LAN
IP (`ipconfig getifaddr en0`). Either:

- **At build time**: create `ios/Config/Local.xcconfig` (not committed):
  ```
  SPACETIME_URL = http:/$()/192.168.1.20:3000
  AGENT_SERVICE_URL = http:/$()/192.168.1.20:8088
  SPACETIME_DB_NAME = kavach
  HOTLINE_NUMBER = +15555550100
  ```
  (`//` starts a comment in xcconfig files, hence `http:/$()/`.) Then `xcodegen generate` and rebuild.
- **At runtime**: Settings → Advanced → Server settings (or "Server settings" on the welcome screen).
  Overrides are stored in the App Group, so the extensions use them too.

Plain HTTP is allowed (ATS local-networking + arbitrary-loads exception) because the backend is a laptop.

To rename the product, change `APP_DISPLAY_NAME` in `Config/Kavach.xcconfig`. The home-screen name, UI
copy and Siri phrases (`\(.applicationName)`) all follow it.

## Running on a device

1. In Xcode, select your team on **all five** targets (app + 4 extensions). Bundle ids are
   `com.kavach.app`, `.CallDirectory`, `.Report`, `.Share`, `.MessageFilter`; change the prefix if your
   team can't use them. Then also change the App Group (`APP_GROUP_ID` in the xcconfig) and
   `CallDirectoryReloader.extensionId` in `App/Services/AppModel.swift`.
2. Capabilities that automatic signing must provision: App Groups (`group.com.kavach.app`) on every
   target, Push Notifications on the app, Keychain Sharing (`com.kavach.shared`).
3. Run the app once and register (name + phone). This stores the token the extensions use.

### Enable the extensions (on the iPhone)

- **Caller labels (Call Directory)**: Settings → Apps → Phone → Call Blocking & Identification → turn on
  Kavach. The app refreshes the label list every 20 s while open and reloads the extension when it changes.
- **Report from Recents (Unwanted Communication)**: Settings → Apps → Phone → SMS/Call Reporting → choose
  Kavach. Then in Phone → Recents, swipe left on a call → Report. The interview opens in the sheet.
- **Text filter (Stretch)**: Settings → Apps → Messages → Unknown Senders → Text Message Filter → Kavach.
- **Share sheet**: share any text, link or screenshot and pick Kavach (first time: "Edit Actions").

### Action Button, Back Tap, Siri

App Shortcuts are registered automatically on install:

- "Open Call Companion in Kavach" (also "Open Kavach Call Companion")
- "Check this with Kavach"
- "I need help in Kavach"

- **Action Button** (iPhone 15 Pro and later): Settings → Action Button → swipe to **Shortcut** →
  choose Kavach → **Open Call Companion**.
- **Back Tap**: Settings → Accessibility → Touch → Back Tap → Double Tap → **Open Call Companion**
  (listed under Shortcuts).

### Push (Trusted Sender Check)

The app registers for APNs after onboarding and saves the hex token with `update_settings`. Pushes in the
`TRUSTED_SENDER` category show **Yes, I sent it** (needs Face ID or passcode, then
`resolve_verification(confirmed)`) and **No, it wasn't me** (`denied`). The payload must carry
`verification_id` at the top level. The same question also appears as a card on Home (from
`my_pending_verifications`), which works without push.

## Debug launch options (DEBUG builds only)

For rehearsals and screenshots on the Simulator:

```sh
SIMCTL_CHILD_KAVACH_DEBUG_TOKEN=<spacetime token> \
SIMCTL_CHILD_KAVACH_DEBUG_ROUTE=companion \   # or check, help, actnow:<incident id>
xcrun simctl launch booted com.kavach.app
```

## What only a device can verify

Call Directory labels on a real incoming call, the Report extension in Recents on iOS 26, Action Button and
Back Tap, CallKit end-of-call events (Call Companion always shows an "I've hung up" button as the
fallback), APNs delivery and Face ID, and the Message Filter.
