# Kavach iOS app

Thin SwiftUI client (spec section 11) plus four extensions. It talks to SpacetimeDB over its HTTP API
(reducers + `my_*` / `caller_labels` / `campaign` reads, polled every 3 s while open) and to the agent
service via `/app/check`, `/app/verify` and `/app/feedback`, using the app's own SpacetimeDB token as the bearer. No
business logic lives here: severity, alerts and floors are all in the module.

## Layout

| Path | What |
| --- | --- |
| `project.yml` | XcodeGen spec → `Kavach.xcodeproj` |
| `Config/Kavach.xcconfig` | `APP_DISPLAY_NAME`, backend URLs, DB name, App Group. The only place the name lives |
| `KavachKit/` | Shared framework: API clients, models, SQL decoding, interview, verdict badge, theme, speech, OCR |
| `App/` | The app: Home, Check a message, Call Companion, Interview, Act now, Network dashboard, Family (Contacts picker), Settings, onboarding, App Intents, push |
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

## Signing in (phone number + texted code)

Onboarding is two steps (`App/Views/OnboardingView.swift`, state in `KavachKit/Networking/SignIn.swift`):

1. Name + mobile number → **Text me a code** mints a SpacetimeDB identity (`POST /v1/identity`) and calls
   `request_sign_in`. The module texts a 6-digit code through the outbox and Photon.
2. The code field uses `.textContentType(.oneTimeCode)`, so iOS offers the code from Messages above the
   keyboard; 6 digits submit automatically (`verify_sign_in`). **Send a new code** unlocks after 30 s;
   **Use a different number** goes back to step 1. Errors are mapped to plain words (`SignInError`): wrong
   code (tries left), expired, too many attempts (locked ~10 min), too many codes (5 per hour).

**Demo numbers:** with `DEMO_MODE=true` on the backend, numbers in the **+1 555-555-xxxx** range (Joe is
`+15555550101`) sign in with the code **`000000`** (no text is sent; they can't receive one). Real numbers
always need the texted code.

Sign out (Settings → Advanced) calls `sign_out` before forgetting the token, which releases the number.
Signing in on another phone moves the number there; this phone notices `my_person` is empty and returns to
the sign-in screen.

## Point the app at your backend

The Simulator reaches the Mac as `127.0.0.1`, so the defaults work there. A real iPhone needs the Mac's LAN
IP (`ipconfig getifaddr en0`). Either:

- **At build time**: create `ios/Config/Local.xcconfig` (not committed):
  ```
  SPACETIME_URL = http:/$()/192.168.1.20:3000
  AGENT_SERVICE_URL = http:/$()/192.168.1.20:8088
  SPACETIME_DB_NAME = kavach
  ```
  (`//` starts a comment in xcconfig files, hence `http:/$()/`.) Then `xcodegen generate` and rebuild.
- **At runtime**: Settings → Advanced → Server settings (or "Server settings" on the welcome screen).
  Overrides are stored in the App Group, so the extensions use them too.

Plain HTTP is allowed (ATS local-networking + arbitrary-loads exception) because the backend is a laptop.

To rename the product, change `APP_DISPLAY_NAME` in `Config/Kavach.xcconfig`. The home-screen name, UI
copy and Siri phrases (`\(.applicationName)`) all follow it.

## Running on a device

1. In Xcode, select your team on **all five** targets (app + 4 extensions). Bundle ids are
   `com.hack.kavach.app`, `.CallDirectory`, `.Report`, `.Share`, `.MessageFilter`; change the prefix if your
   team can't use them. Then also change the App Group (`APP_GROUP_ID` in the xcconfig) and
   `CallDirectoryReloader.extensionId` in `App/Services/AppModel.swift`.
2. Capabilities that automatic signing must provision: App Groups (`group.com.hack.kavach.app`) on every
   target, Push Notifications on the app, Keychain Sharing (`com.hack.kavach.shared`).
3. Run the app once and register (name + phone). This stores the token the extensions use.

### Enable the extensions (on the iPhone)

- **Caller labels (Call Directory)**: Settings → Apps → Phone → Call Blocking & Identification → turn on
  Kavach. The app refreshes the label list every 20 s while open and reloads the extension when it changes.
- **Report from Recents (Unwanted Communication)**: Settings → Apps → Phone → Call Blocking &
  Identification → turn on Kavach, and Settings → Apps → Phone → SMS/Call Reporting → choose Kavach. Then in
  Phone → Recents, swipe left on a call → Report. The shared interview opens in the sheet; the system
  Report/Done button stays disabled until every question is answered.
  - The extension cannot use the network (iOS forbids it for this extension point). It returns an
    `ILClassificationResponse` whose `userInfo` is `{token, caller_e164, answers: {q_*: value}, reported_at,
    request_key}` and iOS POSTs it to `ILClassificationExtensionNetworkReportDestination` =
    `$(AGENT_SERVICE_URL)/ios/call-report` (set in `project.yml`). **That URL must be HTTPS** on a device, so put
    your tunnel URL in `Config/Local.xcconfig` (`AGENT_SERVICE_URL = https:/$()/…`).
  - The report is also saved in the App Group (`pending_call_reports.json`). On every launch/foreground the
    app replays pending reports through `open_incident(report_swipe)` with the same `request_key`, `save_answer`
    (only answers the incident doesn't have yet) and `report_number`, so a POST that never arrived still
    lands and one that did is not duplicated. `request_key` = `ios-report-` + first 40 hex of
    sha256("<caller_e164>|<reported_at micros>").
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

## Call follow-through (Report a call, Your reports)

- **After a call.** `CallFollowUpCenter` keeps one `CXCallObserver` for the app's lifetime. When an
  *incoming* call (ringing or connected) ends while the app is alive, it posts a **local** notification
  (category `CALL_FOLLOWUP`: "Was that a scam call?", actions **Report it** / **It was fine**; no APNs
  needed) and shows the same card on Home. Calls that ended while the app was suspended are found when
  it becomes active again (the call we last saw is gone) and get the Home card if we saw the call in the
  last 30 minutes. Outgoing calls are ignored, each call is handled once, and while Call Companion is
  open it keeps its own end-of-call behaviour (straight to the interview). The decision logic is
  `CallFollowUpTracker` in KavachKit (unit-tested). Home asks to turn notifications on when they're off.
- **Report a call** (notification, Home row under the three actions, I need help, Network → Your
  reports, `kavach://report`): the caller's number (Paste, or "I don't know the number"; iOS never gives
  apps the number), what the community knows about it (`caller_labels`), then `open_incident(report_swipe)`
  with request key `ios-app-report-` + sha256(person|number|start) so the incident exists even if the
  person stops, `save_answer` per question, `report_number` at the end, and the module's result.
- **Your reports** (top of Network, "See all", and an "Unfinished report" banner on Home): every
  incident from `my_incidents`, newest first, labeled Reported from the app / From Recents / During a
  call / By text. Unfinished ones (no `q_shared` yet) resume at the first unanswered question.
- **Forward to Kavach by text.** Check-a-message results, the Share extension ("Text it to Kavach") and
  the "Forward to Kavach" App Shortcut open Messages to the agent with the text wrapped as
  `Forwarded message:` / optional `From: …` / `“message”` (`ForwardToKavach` in KavachKit). Where Messages
  can't open (Simulator) the wrapped text is copied instead.

## Design system

`KavachKit/UI/Theme.swift` and `Components.swift` hold the tokens ("Accessible & Ethical" + Swiss minimalism,
trust-blue profile): one accent (trust blue), status colors green/amber/red (red only for "Likely scam" and
Critical), light/dark/Increase Contrast variants measured for ≥7:1 text, SF Pro text styles only
(`TypeScale`), 4-pt spacing (`Theme.Space`), radii, flat elevation, motion durations that switch off with
Reduce Motion. Screens use `Card`, `StatusBanner`, `KPITile`, `KavachButtonStyle(.primary/.secondary/.destructive/.quiet)`
and `BigActionButton`.

## Contacts

Adding family uses Apple's contact picker (no permission). "Use Contacts" (Family or Settings) asks for
Contacts access only when turned on; it then shows Contacts photos, keeps family names in step with
Contacts (`ContactNameSync`), offers Open in Contacts and suggests likely family from relation labels.
The address book never leaves the phone; only people the person adds go to `upsert_contact`.

## Debug launch options (DEBUG builds only)

For rehearsals and screenshots on the Simulator:

```sh
SIMCTL_CHILD_KAVACH_DEBUG_TOKEN=<spacetime token> \
SIMCTL_CHILD_KAVACH_DEBUG_ROUTE=companion \   # or check, help, actnow:<incident id>
xcrun simctl launch booted com.hack.kavach.app
```

Also: `KAVACH_DEBUG_SPACETIME_URL`, `KAVACH_DEBUG_DB`, `KAVACH_DEBUG_AGENT_URL` (backend overrides),
`KAVACH_DEBUG_TAB=network|family|settings`, `KAVACH_DEBUG_TEXT` + `KAVACH_DEBUG_AUTOCHECK=1` (check a
prefilled message), `KAVACH_DEBUG_FAMILY=picker|form|manual`, `KAVACH_DEBUG_CONTACTS=1`,
`KAVACH_DEBUG_SCROLL=bottom|center`, `KAVACH_DEBUG_NO_PUSH_PROMPT=1` (also hides the notifications card),
`KAVACH_DEBUG_ROUTE=report` (+ `KAVACH_DEBUG_REPORT_NUMBER=<number>`), `KAVACH_DEBUG_ROUTE=interview:<incident id>`
(+ `KAVACH_DEBUG_RESULT=1` to open on the result), `KAVACH_DEBUG_CALL_FOLLOWUP=1` (pretend a call just ended).
Sign-in screenshots (signed out): `KAVACH_DEBUG_SIGNIN_PHONE` + `KAVACH_DEBUG_SIGNIN_NAME` prefill step 1,
`KAVACH_DEBUG_SIGNIN=code` also sends the code, `KAVACH_DEBUG_SIGNIN_CODE=<6 digits>` then enters it.

## What only a device can verify

Call Directory labels on a real incoming call, the Report extension in Recents on iOS 26 (and iOS delivering its POST to `/ios/call-report`), Action Button and
Back Tap, CallKit end-of-call events (Call Companion always shows an "I've hung up" button as the
fallback; the app-wide "Was that a scam call?" follow-up is covered by unit tests of `CallFollowUpTracker`),
the Messages compose sheet / `sms:` body prefill, APNs delivery and Face ID, and the Message Filter.
