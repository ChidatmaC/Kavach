import Foundation

/// Everything the app (and its extensions) do against the backend, acting as the app's own person.
/// No business logic: reducers decide severity, alerts and floors (D2, D9).
public struct KavachAPI: Sendable {
    public let db: SpacetimeClient
    public let agents: AgentClient
    public let token: String

    public init(config: AppConfig, token: String) {
        self.db = SpacetimeClient(config: config)
        self.agents = AgentClient(baseURL: config.agentURL)
        self.token = token
    }

    public init(db: SpacetimeClient, agents: AgentClient, token: String) {
        self.db = db
        self.agents = agents
        self.token = token
    }

    /// The configured API using the stored token, if the device has registered.
    public static func stored(config: AppConfig = .current) -> KavachAPI? {
        guard let t = SharedStore(appGroup: config.appGroup).loadToken() else { return nil }
        return KavachAPI(config: config, token: t)
    }

    // MARK: Onboarding

    /// Mints an identity (if needed), registers the person and stores the token.
    public static func register(config: AppConfig, phone: String, name: String) async throws -> (KavachAPI, Person) {
        let store = SharedStore(appGroup: config.appGroup)
        let db = SpacetimeClient(config: config)
        let token: String
        if let t = store.loadToken() { token = t } else { token = try await db.newIdentity().token }
        let api = KavachAPI(config: config, token: token)
        try await api.registerPerson(phone: phone, name: name)
        guard let me = try await api.myPerson() else { throw KavachError.notRegistered }
        store.saveToken(token)
        store.set(me.id, .personId)
        store.set(me.displayName, .personName)
        return (api, me)
    }

    public func registerPerson(phone: String, name: String) async throws {
        try await db.call("register_person", ["phone": .string(phone), "name": .string(name)], token: token)
    }

    // MARK: Reads (views)

    public func myPerson() async throws -> Person? {
        try await db.query("SELECT * FROM my_person", as: Person.self, token: token).first
    }
    public func myContacts() async throws -> [Contact] {
        try await db.query("SELECT * FROM my_contacts", as: Contact.self, token: token)
    }
    public func myIncidents() async throws -> [Incident] {
        try await db.query("SELECT * FROM my_incidents", as: Incident.self, token: token)
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func incident(requestKey: String) async throws -> Incident? {
        try await db.query("SELECT * FROM my_incidents WHERE request_key = \(sqlQuote(requestKey))",
                           as: Incident.self, token: token).first
    }
    public func myRecoverySteps() async throws -> [RecoveryStep] {
        try await db.query("SELECT * FROM my_recovery_steps", as: RecoveryStep.self, token: token)
            .sorted { ($0.incidentId, $0.sortOrder, $0.id) < ($1.incidentId, $1.sortOrder, $1.id) }
    }
    public func myChecks() async throws -> [MessageCheck] {
        try await db.query("SELECT * FROM my_checks", as: MessageCheck.self, token: token)
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func myBriefings() async throws -> [Briefing] {
        try await db.query("SELECT * FROM my_briefings", as: Briefing.self, token: token)
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func myDrills() async throws -> [Drill] {
        try await db.query("SELECT * FROM my_drills", as: Drill.self, token: token)
    }
    public func myPendingVerifications() async throws -> [Verification] {
        try await db.query("SELECT * FROM my_pending_verifications", as: Verification.self, token: token)
    }
    public func callerLabels() async throws -> [CallerLabel] {
        try await db.query("SELECT * FROM caller_labels", as: CallerLabel.self, token: token)
            .sorted { ($0.callKitNumber ?? 0) < ($1.callKitNumber ?? 0) }
    }
    public func campaigns() async throws -> [Campaign] {
        try await db.query("SELECT * FROM campaign", as: Campaign.self, token: token)
            .sorted { $0.weeklyReports > $1.weeklyReports }
    }

    // MARK: Reducers

    /// Opens an incident and returns it (reducers return nothing; read back by request_key).
    public func openIncident(personId: UInt64, entryPoint: String, callerE164: String = "") async throws -> Incident {
        let key = UUID().uuidString.lowercased()
        try await db.call("open_incident", [
            "request_key": .string(key), "person_id": .id(personId),
            "entry_point": .string(entryPoint), "caller_e164": .string(callerE164),
        ], token: token)
        guard let inc = try await incident(requestKey: key) else { throw KavachError.notFound("the new report") }
        return inc
    }

    public func saveAnswer(incidentId: UInt64, questionId: String, answer: String) async throws {
        try await db.call("save_answer", [
            "incident_id": .id(incidentId), "question_id": .string(questionId), "answer": .string(answer),
        ], token: token)
    }

    public func resolveIncident(_ id: UInt64) async throws {
        try await db.call("resolve_incident", ["incident_id": .id(id)], token: token)
    }

    public func markStepDone(stepId: UInt64, done: Bool) async throws {
        try await db.call("mark_step_done", ["step_id": .id(stepId), "done": .bool(done)], token: token)
    }

    public func tellMyFamily(incidentId: UInt64) async throws {
        try await db.call("tell_my_family", ["incident_id": .id(incidentId)], token: token)
    }

    public func reportValue(personId: UInt64, kind: String, value: String) async throws {
        try await db.call("report_number", [
            "person_id": .id(personId), "kind": .string(kind), "value": .string(value),
        ], token: token)
    }

    public func setSharingPaused(personId: UInt64, paused: Bool) async throws {
        try await db.call("set_sharing_paused", ["person_id": .id(personId), "paused": .bool(paused)], token: token)
    }

    /// `update_settings` takes every field; start from the current person and change what you need.
    public func updateSettings(_ p: Person) async throws {
        try await db.call("update_settings", [
            "person_id": .id(p.id),
            "accessibility_mode": .bool(p.accessibilityMode),
            "sharing_paused": .bool(p.sharingPaused),
            "critical_overrides_pause": .bool(p.criticalOverridesPause),
            "practice_consent": .bool(p.practiceConsent),
            "apns_token": .string(p.apnsToken),
            "family_code_word": .string(p.familyCodeWord),
            "tz_offset_minutes": .int(Int64(p.tzOffsetMinutes)),
        ], token: token)
    }

    public func upsertContact(personId: UInt64, contactId: UInt64 = 0, name: String, phone: String,
                              relationship: String, channel: ContactChannel, isEmergency: Bool) async throws {
        try await db.call("upsert_contact", [
            "person_id": .id(personId), "contact_id": .id(contactId), "name": .string(name),
            "phone_e164": .string(phone), "relationship": .string(relationship),
            "channel": .string(channel.rawValue), "is_emergency_contact": .bool(isEmergency),
        ], token: token)
    }

    public func removeContact(_ id: UInt64) async throws {
        try await db.call("remove_contact", ["contact_id": .id(id)], token: token)
    }

    public func resolveVerification(id: UInt64, confirmed: Bool) async throws {
        try await db.call("resolve_verification", [
            "verification_id": .id(id), "result": .string(confirmed ? "confirmed" : "denied"),
        ], token: token)
    }

    public func scheduleDrill(personId: UInt64, contactId: UInt64, templateKey: String, sendAt: Date) async throws {
        try await db.call("schedule_drill", [
            "person_id": .id(personId), "contact_id": .id(contactId), "template_key": .string(templateKey),
            "send_at_micros": .int(STTimestamp(date: sendAt).micros),
        ], token: token)
    }

    public func requestBriefing(personId: UInt64) async throws {
        try await db.call("request_briefing", ["person_id": .id(personId)], token: token)
    }

    // MARK: Agent service (/app/*)

    public func check(text: String, source: CheckSource, senderE164: String? = nil) async -> CheckResult {
        await agents.check(text: text, source: source, senderE164: senderE164, token: token)
    }

    public func verifyRelative(name: String) async throws -> VerifyResult {
        try await agents.verify(relativeName: name, token: token)
    }
}

/// E.164 normalization for typed US numbers: "(555) 555-0101" → "+15555550101". Display-input helper only;
/// the module validates.
public func normalizePhone(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.filter(\.isNumber)
    if trimmed.hasPrefix("+") { return "+" + digits }
    if digits.count == 10 { return "+1" + digits }
    if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
    return digits.isEmpty ? "" : "+" + digits
}
