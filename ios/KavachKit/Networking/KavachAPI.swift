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

    // MARK: Onboarding (sign-in by texted code: see SignIn.swift and `SignInFlow`)

    /// Tests and demo personas only: signs in a +1555555xxxx number with the demo code 000000
    /// (module running with DEMO_MODE=true). Real numbers must use request/verify with the texted code.
    /// Errors stay raw `KavachError.http` (the module's text).
    public func registerPerson(phone: String, name: String) async throws {
        try await db.call("request_sign_in", ["phone": .string(phone), "name": .string(name)], token: token)
        try await db.call("verify_sign_in", ["phone": .string(phone), "code": .string("000000")], token: token)
        guard try await myPerson()?.phoneE164 == phone else { throw KavachError.notRegistered }
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
    public func myAlertRequests() async throws -> [AlertRequest] {
        try await db.query("SELECT * FROM my_alert_requests", as: AlertRequest.self, token: token)
            .sorted { $0.createdAt > $1.createdAt }
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
        try await openIncident(requestKey: UUID().uuidString.lowercased(), personId: personId, entryPoint: entryPoint,
                               callerE164: callerE164)
    }

    /// Idempotent by `requestKey`: calling it again returns the incident created the first time.
    public func openIncident(requestKey key: String, personId: UInt64, entryPoint: String, callerE164: String = "") async throws -> Incident {
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

    /// "Was this right?" (`/app/feedback`). Never throws; returns whether the service accepted it.
    @discardableResult
    public func sendFeedback(_ feedback: VerdictFeedback, checkId: UInt64?, requestKey: String?) async -> Bool {
        await agents.feedback(feedback, checkId: checkId, requestKey: requestKey, token: token)
    }
}
