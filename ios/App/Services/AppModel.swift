import CallKit
import Foundation
import KavachKit
import Observation
import SwiftUI
import UserNotifications

/// Where the app should go next (set by App Intents, notifications and severity changes).
enum Route: Hashable, Identifiable {
    case check(prefill: String?)
    case companion
    case needHelp
    case actNow(incidentId: UInt64)
    case interview(incidentId: UInt64)
    /// Report a call: number, then the 5 questions (notification, Home, I need help, Your reports).
    case reportCall

    var id: String {
        switch self {
        case .check: "check"
        case .companion: "companion"
        case .needHelp: "needHelp"
        case .actNow(let i): "actNow-\(i)"
        case .interview(let i): "interview-\(i)"
        case .reportCall: "reportCall"
        }
    }
}

/// App state. Mirrors the `my_*` views by polling (HTTP clients have no subscriptions) and turns
/// taps into reducer calls. No business logic: severity, alerts and floors live in the module.
@Observable
final class AppModel {
    static let shared = AppModel()

    var config = AppConfig.current
    private(set) var api: KavachAPI?

    /// Device-local display preferences. `prefs` overlays Accessibility Mode from the (optimistic)
    /// person row, so the whole app switches the moment the toggle flips or a poll brings a change.
    var localPrefs = DisplayPreferences.load()
    var prefs: DisplayPreferences {
        get {
            var p = localPrefs
            if let person { p.accessibilityMode = person.accessibilityMode }
            return p
        }
        set { localPrefs = newValue }
    }

    /// The person row the UI reads: last `my_person` poll plus in-flight toggle changes.
    /// Views must read toggles from here (never from a local copy) so polled changes, like the person
    /// texting "pause" to the agent, show up.
    let settings = PersonSettingsState()
    var person: Person? { settings.person }

    /// Optional Contacts integration (photos, name sync, suggestions).
    let contactsBridge = ContactsBridge(store: SharedStore(appGroup: AppConfig.current.appGroup))

    /// nil until the Save-to-Contacts step was handled (App Group, shown once).
    var agentContactPrompt: AgentContactPrompt?
    var contacts: [Contact] = []
    var incidents: [Incident] = []
    var steps: [RecoveryStep] = []
    var checks: [MessageCheck] = []
    var briefings: [Briefing] = []
    var alertRequests: [AlertRequest] = []
    var pendingVerifications: [Verification] = []
    var campaigns: [Campaign] = []
    var callerLabelCount = 0
    /// Public `caller_labels` feed (also cached for the Call Directory extension).
    var callerLabels: [CallerLabel] = []
    /// An incoming call ended recently and we haven't asked about it yet (Home card).
    var callFollowUpPending = false
    /// The call behind that card was never connected (missed or declined): gentler wording.
    var callFollowUpMissed = false
    /// nil until read; Home explains why notifications matter when they're off.
    var notificationStatus: UNAuthorizationStatus?

    var route: Route?
    var connectionProblem: String?
    var lastError: String?

    private var pollTask: Task<Void, Never>?
    private var labelsTask: Task<Void, Never>?
    private var seenCriticalIds: Set<UInt64> = []
    private var store: SharedStore { SharedStore(appGroup: config.appGroup) }

    init() {
        #if DEBUG
        // Simulator/demo setup: `SIMCTL_CHILD_KAVACH_DEBUG_TOKEN=<token> xcrun simctl launch ...`
        // signs in with an existing SpacetimeDB token (and optional KAVACH_DEBUG_PERSON_ID).
        let env = ProcessInfo.processInfo.environment
        // Point a Simulator run at a local backend without touching the xcconfig.
        if let u = env["KAVACH_DEBUG_SPACETIME_URL"] { store.set(u, .spacetimeURLOverride) }
        if let d = env["KAVACH_DEBUG_DB"] { store.set(d, .databaseOverride) }
        if let a = env["KAVACH_DEBUG_AGENT_URL"] { store.set(a, .agentURLOverride) }
        config = AppConfig.current
        if let t = env["KAVACH_DEBUG_TOKEN"], !t.isEmpty {
            store.saveToken(t)
            if let pid = UInt64(env["KAVACH_DEBUG_PERSON_ID"] ?? "") { store.set(pid, .personId) }
        }
        switch env["KAVACH_DEBUG_ROUTE"] {
        case "companion": route = .companion
        case "check": route = .check(prefill: env["KAVACH_DEBUG_TEXT"])
        case "help": route = .needHelp
        case let r? where r.hasPrefix("actnow:"): route = UInt64(r.dropFirst(7)).map { .actNow(incidentId: $0) }
        case let r? where r.hasPrefix("interview:"): route = UInt64(r.dropFirst(10)).map { .interview(incidentId: $0) }
        case "report": route = .reportCall
        default: break
        }
        #endif
        #if DEBUG
        switch env["KAVACH_DEBUG_CONTACT_PROMPT"] {
        case "reset": AgentContactPrompt.save(nil, to: store)
        case "saved": AgentContactPrompt.save(.saved, to: store)
        case "dismissed": AgentContactPrompt.save(.dismissed, to: store)
        default: break
        }
        debugTab = env["KAVACH_DEBUG_TAB"]
        if env["KAVACH_DEBUG_CONTACTS"] == "1" { Task { _ = await contactsBridge.enable() } }
        debugShowContactCard = env["KAVACH_DEBUG_SHOW_CONTACT_CARD"] == "1"
        debugReportNumber = env["KAVACH_DEBUG_REPORT_NUMBER"]
        debugHideNotificationCard = env["KAVACH_DEBUG_NO_PUSH_PROMPT"] == "1"
        #endif
        agentContactPrompt = AgentContactPrompt.load(from: store)
        api = KavachAPI.stored(config: config)
        checkAgentContactExists()
    }

    #if DEBUG
    var debugTab: String?
    var debugShowContactCard = false
    var debugReportNumber: String?
    var debugHideNotificationCard = false
    #endif

    var isRegistered: Bool { api != nil }
    /// Consecutive successful polls that found no person for this sign-in.
    private var missingPersonPolls = 0
    /// Shown on the sign-up screen after an automatic sign-out.
    var signedOutNotice: String?

    // MARK: Onboarding

    /// The texted code was verified (`SignInFlow`): keep the session and start polling.
    func completeSignIn(api: KavachAPI, person me: Person) async {
        api.remember(me, config: config)
        self.api = api
        signedOutNotice = nil
        settings.replace(me)
        syncAccessibilityPref()
        checkAgentContactExists()
        await refresh()
        startPolling()
        // Otherwise asked when the Save-to-Contacts step is handled, so prompts don't stack.
        if !shouldOfferAgentContact { PushRegistrar.shared.requestAuthorization() }
    }

    /// Releases the number on the server (`sign_out`), then forgets the token on this phone.
    /// Offline, the local sign-out still happens; the next sign-in elsewhere takes the number over.
    func signOut() async {
        stopPolling()
        if let api { try? await api.signOut() }
        clearSession()
    }

    /// Local part of sign-out (also used when the server already dropped this sign-in).
    private func clearSession() {
        stopPolling()
        missingPersonPolls = 0
        store.clearToken()
        api = nil
        settings.replace(nil)
        contacts = []; incidents = []; steps = []; checks = []; briefings = []; alertRequests = []
    }

    func reloadConfig() {
        config = AppConfig.current
        if let t = api?.token { api = KavachAPI(config: config, token: t) }
    }

    // MARK: Polling

    func startPolling() {
        guard api != nil, pollTask == nil else { return }
        Task { await replayCallReports() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // Caller labels refresh well under the 60 s target (spec 13).
        labelsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLabelsAndCampaigns()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel(); pollTask = nil
        labelsTask?.cancel(); labelsTask = nil
    }

    func refresh() async {
        guard let api else { return }
        let fetch = settings.beginFetch()
        do {
            async let p = api.myPerson()
            async let c = api.myContacts()
            async let i = api.myIncidents()
            async let s = api.myRecoverySteps()
            async let k = api.myChecks()
            async let b = api.myBriefings()
            async let v = api.myPendingVerifications()
            async let a = api.myAlertRequests()
            let (np, nc, ni, ns, nk, nb, nv, na) = try await (p, c, i, s, k, b, v, a)
            settings.receive(np, fetch: fetch)
            if contacts != nc { contacts = nc }
            if contactsBridge.isActive { Task { await syncContacts() } }
            if incidents != ni { incidents = ni; noticeCriticalIncidents(ni) }
            if steps != ns { steps = ns }
            if checks != nk { checks = nk }
            if briefings != nb { briefings = nb }
            if pendingVerifications != nv { pendingVerifications = nv }
            if alertRequests != na { alertRequests = na }
            syncAccessibilityPref()
            if let np {
                store.set(np.id, .personId)
                missingPersonPolls = 0
            } else {
                // Reachable, but this sign-in no longer has a person (e.g. the account was removed or the
                // demo database was reset). Requests would fail with "not your person": sign up again.
                missingPersonPolls += 1
                if missingPersonPolls >= 2 {
                    clearSession()
                    signedOutNotice = "This phone was signed out, maybe because your number signed in on another phone. Sign in again to keep protecting you."
                    return
                }
            }
            connectionProblem = nil
        } catch {
            connectionProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshLabelsAndCampaigns() async {
        guard let api else { return }
        if let cs = try? await api.campaigns(), cs != campaigns { campaigns = cs }
        guard let labels = try? await api.callerLabels() else { return }
        callerLabelCount = labels.count
        if callerLabels != labels { callerLabels = labels }
        let previous = store.loadCallerLabels()
        if previous != labels {
            try? store.saveCallerLabels(labels)
            CallDirectoryReloader.reload()
        }
    }

    /// Critical: open the Act now screen (spec 8, step 1) and speak it in Accessibility Mode.
    private func noticeCriticalIncidents(_ list: [Incident]) {
        let critical = list.filter { $0.severityLevel == .critical && !$0.isResolved }
        let fresh = critical.filter { !seenCriticalIds.contains($0.id) }
        seenCriticalIds.formUnion(critical.map(\.id))
        defer { didLoadIncidents = true }
        guard didLoadIncidents, let newest = fresh.first else { return }
        if case .interview = route { return } // the interview shows its own result first
        if route == .reportCall { return }
        route = .actNow(incidentId: newest.id)
        if prefs.autoSpeak { Speaker.shared.speak("Act now. Follow these steps, one at a time. Your family is being told.") }
    }
    private var didLoadIncidents = false

    // MARK: Derived (display only)

    var personId: UInt64 { person?.id ?? store.uint64(.personId) }

    var activeIncident: Incident? {
        incidents.first { !$0.isResolved && $0.severityLevel >= .high && !steps(for: $0.id).isEmpty }
    }

    func steps(for incidentId: UInt64) -> [RecoveryStep] {
        steps.filter { $0.incidentId == incidentId }
    }

    var emergencyContact: Contact? {
        contacts.first(where: \.isEmergencyContact) ?? contacts.first { $0.consentStatus == "accepted" }
    }

    /// The Network dashboard (and Home's status line) from the polled views.
    var dashboard: NetworkDashboard {
        NetworkDashboard(checks: checks, incidents: incidents, alertRequests: alertRequests, contacts: contacts,
                         campaigns: campaigns, briefings: briefings)
    }

    /// "Scams stopped this week": likely-scam checks plus incidents where nothing was shared.
    var scamsStoppedThisWeek: Int { dashboard.scamsStopped }

    /// Family replies worth showing now (Home banners), urgent first.
    var relevantAlertRequests: [AlertRequest] { FamilyReplies.relevant(alertRequests) }

    func alertRequest(for incidentId: UInt64) -> AlertRequest? {
        FamilyReplies.latest(for: incidentId, in: alertRequests)
    }

    func contact(_ id: UInt64) -> Contact? { contacts.first { $0.id == id } }

    // MARK: Reports

    /// "Your reports": every incident (app, Recents, Call Companion, by text), newest first.
    var reports: [ReportSummary] { ReportsList.make(incidents) }

    /// Open reports whose questionnaire isn't finished (Home banner).
    var unfinishedReports: [ReportSummary] { ReportsList.unfinished(incidents) }

    /// Where an interview for this incident starts: the first unanswered question (call reports with
    /// no answers start at "Did you answer the call?").
    func interviewStart(for incidentId: UInt64) -> Int {
        guard let inc = incidents.first(where: { $0.id == incidentId }) else { return 0 }
        return ReportsList.firstUnanswered(inc.answers, askAnswered: ReportsList.asksAnswered(inc)) ?? 0
    }

    /// Whether this incident's interview asks "Did you answer the call?" (reports about a call).
    func asksAnswered(for incidentId: UInt64) -> Bool {
        incidents.first(where: { $0.id == incidentId }).map(ReportsList.asksAnswered) ?? false
    }

    /// Number to report to the community when a report's interview is finished (reported calls only).
    func reportNumber(for incidentId: UInt64) -> String {
        guard let inc = incidents.first(where: { $0.id == incidentId }), inc.entryPoint == ReportDraft.entryPoint else { return "" }
        return inc.callerE164
    }

    /// Opens the incident for an in-app report (idempotent by the draft's request key).
    func openReport(_ draft: ReportDraft) async -> Incident? {
        guard let api else { lastError = KavachError.notRegistered.errorDescription; return nil }
        do {
            let inc = try await ReportFiling.open(draft, backend: api)
            lastError = nil
            await refresh()
            return inc
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: Notifications

    func refreshNotificationStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if notificationStatus != s { notificationStatus = s }
    }

    /// Home explains why notifications matter while they are off.
    var showsNotificationCard: Bool {
        #if DEBUG
        if debugHideNotificationCard { return false }
        #endif
        guard let s = notificationStatus else { return false }
        return s == .notDetermined || s == .denied
    }

    // MARK: Actions

    func run(_ op: @escaping (KavachAPI) async throws -> Void) async -> Bool {
        guard let api else { lastError = KavachError.notRegistered.errorDescription; return false }
        do {
            try await op(api)
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func openIncident(entryPoint: String, callerE164: String = "") async -> Incident? {
        guard let api else { return nil }
        do {
            let inc = try await api.openIncident(personId: personId, entryPoint: entryPoint, callerE164: callerE164)
            await refresh()
            return inc
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Non-toggle settings (code word, APNs token): written with `update_settings`, shown once accepted.
    func updateSettings(_ change: (inout Person) -> Void) async {
        guard var p = person else { return }
        change(&p)
        let target = p
        if await run({ try await $0.updateSettings(target) }) { settings.commit(target) }
    }

    /// Flips a person toggle optimistically (icon, color and status change at once), writes it, and
    /// reverts with the error shown if the reducer call fails. Sharing uses `set_sharing_paused`
    /// (the same reducer the agent's "pause"/"resume" text commands use); the rest `update_settings`.
    @discardableResult
    func setSetting(_ setting: SettingToggle, _ value: Bool) async -> Bool {
        guard let api else { lastError = KavachError.notRegistered.errorDescription; return false }
        let ok = await settings.set(setting, to: value) { p in
            if setting == .sharingPaused {
                try await api.setSharingPaused(personId: p.id, paused: value)
            } else {
                try await api.updateSettings(p)
            }
        }
        lastError = settings.lastError
        syncAccessibilityPref()
        return ok
    }

    func setAccessibilityMode(_ on: Bool) async { await setSetting(.accessibilityMode, on) }

    /// Binding for a person toggle that always reads the polled/optimistic row.
    func binding(for setting: SettingToggle) -> Binding<Bool> {
        guard let kp = setting.personKeyPath else { return .constant(false) }
        return Binding(get: { [weak self] in self?.person?[keyPath: kp] ?? false },
                       set: { [weak self] v in Task { await self?.setSetting(setting, v) } })
    }

    /// Keeps the App Group copy of Accessibility Mode (read by the extensions) in step with the person row.
    private func syncAccessibilityPref() {
        guard let p = person, localPrefs.accessibilityMode != p.accessibilityMode else { return }
        localPrefs.accessibilityMode = p.accessibilityMode
        localPrefs.save(to: store)
    }

    // MARK: Agent contact

    var agentNumber: String { config.agentLineNumber }
    var shouldOfferAgentContact: Bool { isRegistered && agentContactPrompt == nil && !agentNumber.isEmpty }

    func markAgentContact(_ value: AgentContactPrompt) {
        let wasOffering = shouldOfferAgentContact
        agentContactPrompt = value
        AgentContactPrompt.save(value, to: store)
        if wasOffering { PushRegistrar.shared.requestAuthorization() }
    }

    /// Skips the step when the number is already a contact, but only if Contacts access was granted
    /// already; we never ask for that permission just for this.
    func checkAgentContactExists() {
        guard agentContactPrompt == nil, !agentNumber.isEmpty,
              AgentContact.existsWithoutPrompting(number: agentNumber) else { return }
        markAgentContact(.saved)
    }

    func savePrefs() { localPrefs.save(to: store) }

    // MARK: Contacts

    /// Photos and suggestions from Contacts; saves family names that changed in Contacts.
    func syncContacts(force: Bool = false) async {
        let updates = await contactsBridge.sync(family: contacts, force: force)
        for (c, name) in updates {
            _ = await run { api in
                try await api.upsertContact(personId: self.personId, contactId: c.id, name: name, phone: c.phoneE164,
                                            relationship: c.relationship, channel: c.channelKind ?? .sms,
                                            isEmergency: c.isEmergencyContact)
            }
        }
    }

    /// Adds (or edits) a family member. Returns the saved contact (read back by number).
    func saveFamilyMember(_ d: FamilyDraft, editing: Contact? = nil) async -> Contact? {
        guard let phone = PhoneNumbers.e164(d.phoneE164) else {
            lastError = "That number doesn't look right. Use a 10-digit US number or start with +."
            return nil
        }
        let ok = await run { api in
            try await api.upsertContact(personId: self.personId, contactId: editing?.id ?? 0, name: d.trimmedName,
                                        phone: phone, relationship: d.relationship, channel: d.channel,
                                        isEmergency: d.isEmergencyContact)
        }
        guard ok else { return nil }
        let saved = contacts.first { $0.phoneE164 == phone }
        if let saved, let id = d.contactIdentifier {
            contactsBridge.link(contactId: saved.id, identifier: id, name: d.trimmedName)
        }
        return saved
    }

    // MARK: Calls reported from Recents

    private var replaying = false

    /// Replays reports the Unwanted Communication extension saved in the App Group (in case iOS's
    /// POST to /ios/call-report never arrived). Idempotent by request key.
    func replayCallReports() async {
        guard let api, !replaying else { return }
        replaying = true
        defer { replaying = false }
        let reports = CallReportStore(store: store)
        guard !reports.pending().isEmpty else { return }
        let pid = personId != 0 ? personId : ((try? await api.myPerson())?.id ?? 0)
        let out = await CallReportReplayer.replay(store: reports, backend: api, token: api.token, personId: pid)
        if !out.replayed.isEmpty { await refresh() }
    }

    // MARK: Feedback

    /// "Was this right?" Fire-and-forget; never blocks the result screen.
    func sendFeedback(_ fb: VerdictFeedback, for result: CheckResult) async {
        guard let api else { return }
        await api.sendFeedback(fb, checkId: result.checkId, requestKey: result.requestKey)
    }

    func saveAPNsToken(_ token: String) async {
        store.set(token, .apnsToken)
        guard person != nil, person?.apnsToken != token else { return }
        await updateSettings { $0.apnsToken = token }
    }
}

enum CallDirectoryReloader {
    static let extensionId = "com.hack.kavach.app.CallDirectory"
    static func reload() {
        CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier: extensionId) { _ in }
    }
    static func status() async -> CXCallDirectoryManager.EnabledStatus {
        await withCheckedContinuation { cont in
            CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(withIdentifier: extensionId) { s, _ in
                cont.resume(returning: s)
            }
        }
    }
}
