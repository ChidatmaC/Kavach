import CallKit
import Foundation
import KavachKit
import Observation

/// Where the app should go next (set by App Intents, notifications and severity changes).
enum Route: Hashable, Identifiable {
    case check(prefill: String?)
    case companion
    case needHelp
    case actNow(incidentId: UInt64)
    case interview(incidentId: UInt64)

    var id: String {
        switch self {
        case .check: "check"
        case .companion: "companion"
        case .needHelp: "needHelp"
        case .actNow(let i): "actNow-\(i)"
        case .interview(let i): "interview-\(i)"
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
    var prefs = DisplayPreferences.load()

    var person: Person?
    var contacts: [Contact] = []
    var incidents: [Incident] = []
    var steps: [RecoveryStep] = []
    var checks: [MessageCheck] = []
    var briefings: [Briefing] = []
    var drills: [Drill] = []
    var pendingVerifications: [Verification] = []
    var campaigns: [Campaign] = []
    var callerLabelCount = 0

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
        if let t = env["KAVACH_DEBUG_TOKEN"], !t.isEmpty {
            store.saveToken(t)
            if let pid = UInt64(env["KAVACH_DEBUG_PERSON_ID"] ?? "") { store.set(pid, .personId) }
        }
        switch env["KAVACH_DEBUG_ROUTE"] {
        case "companion": route = .companion
        case "check": route = .check(prefill: env["KAVACH_DEBUG_TEXT"])
        case "help": route = .needHelp
        case let r? where r.hasPrefix("actnow:"): route = UInt64(r.dropFirst(7)).map { .actNow(incidentId: $0) }
        default: break
        }
        #endif
        api = KavachAPI.stored(config: config)
    }

    var isRegistered: Bool { api != nil }

    // MARK: Onboarding

    func register(phone: String, name: String) async throws {
        let (api, me) = try await KavachAPI.register(config: config, phone: normalizePhone(phone), name: name)
        self.api = api
        person = me
        await refresh()
        startPolling()
        PushRegistrar.shared.requestAuthorization()
    }

    func signOut() {
        stopPolling()
        store.clearToken()
        api = nil
        person = nil
        contacts = []; incidents = []; steps = []; checks = []; briefings = []; drills = []
    }

    func reloadConfig() {
        config = AppConfig.current
        if let t = api?.token { api = KavachAPI(config: config, token: t) }
    }

    // MARK: Polling

    func startPolling() {
        guard api != nil, pollTask == nil else { return }
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
        do {
            async let p = api.myPerson()
            async let c = api.myContacts()
            async let i = api.myIncidents()
            async let s = api.myRecoverySteps()
            async let k = api.myChecks()
            async let b = api.myBriefings()
            async let v = api.myPendingVerifications()
            async let d = api.myDrills()
            let (np, nc, ni, ns, nk, nb, nv, nd) = try await (p, c, i, s, k, b, v, d)
            if person != np { person = np }
            if contacts != nc { contacts = nc }
            if incidents != ni { incidents = ni; noticeCriticalIncidents(ni) }
            if steps != ns { steps = ns }
            if checks != nk { checks = nk }
            if briefings != nb { briefings = nb }
            if pendingVerifications != nv { pendingVerifications = nv }
            if drills != nd { drills = nd }
            if let np, np.accessibilityMode != prefs.accessibilityMode {
                prefs.accessibilityMode = np.accessibilityMode
                prefs.save(to: store)
            }
            if let np { store.set(np.id, .personId) }
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

    private var weekAgo: Int64 { STTimestamp(date: Date().addingTimeInterval(-7 * 86400)).micros }

    var checksThisWeek: [MessageCheck] { checks.filter { $0.createdAt.micros >= weekAgo } }

    /// "Scams stopped this week": likely-scam checks plus incidents where nothing was shared.
    var scamsStoppedThisWeek: Int {
        checksThisWeek.filter { $0.verdictKind == .likelyScam }.count
            + incidents.filter { $0.createdAt.micros >= weekAgo && ($0.severityLevel == .low || $0.severityLevel == .medium) }.count
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

    func updateSettings(_ change: (inout Person) -> Void) async {
        guard var p = person else { return }
        change(&p)
        person = p
        _ = await run { try await $0.updateSettings(p) }
    }

    func setAccessibilityMode(_ on: Bool) async {
        prefs.accessibilityMode = on
        prefs.save(to: store)
        await updateSettings { $0.accessibilityMode = on }
    }

    func savePrefs() { prefs.save(to: store) }

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
