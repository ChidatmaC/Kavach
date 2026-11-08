import XCTest
@testable import KavachKit

/// Live tests of the API client against a local SpacetimeDB (`kavach-ios`, seeded with demo_reset).
/// Skipped when the server is not reachable.
final class APIIntegrationTests: XCTestCase {
    private var db: SpacetimeClient!
    private var token: String!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["KAVACH_TEST_SPACETIME_URL"] ?? "http://127.0.0.1:3000")!
        db = SpacetimeClient(baseURL: url, database: env["KAVACH_TEST_DB"] ?? "kavach-ios")
        do { token = try await db.newIdentity().token }
        catch { throw XCTSkip("SpacetimeDB not reachable at \(url): \(error)") }
    }

    private var api: KavachAPI { KavachAPI(db: db, agents: AgentClient(baseURL: URL(string: "http://127.0.0.1:9")!), token: token) }

    /// Demo range: signs in with the demo code 000000 (DEMO_MODE=true on kavach-ios).
    private func randomPhone() -> String { "+1555555" + String(format: "%04d", Int.random(in: 1_000...9_999)) }

    func testRegisterAndReadMyPerson() async throws {
        let phone = randomPhone()
        try await api.registerPerson(phone: phone, name: "iOS Test")
        let me = try await api.myPerson()
        XCTAssertEqual(me?.phoneE164, phone)
        XCTAssertEqual(me?.displayName, "iOS Test")
        XCTAssertEqual(me?.accessibilityMode, false)
        XCTAssertEqual(me?.recoveryWatchUntil.isSet, false)
        XCTAssertTrue(me?.createdAt.isSet ?? false)
    }

    func testReducerErrorTextIsSurfaced() async throws {
        do {
            try await api.registerPerson(phone: "bad", name: "x")
            XCTFail("expected an error")
        } catch let KavachError.http(status, message) {
            XCTAssertEqual(status, 530)
            XCTAssertTrue(message.contains("E.164"), message)
        }
    }

    /// Report extension path: open_incident(report_swipe) + save_answer → High for personal_details,
    /// with matching recovery steps.
    func testInterviewPersonalDetailsReachesHighWithSteps() async throws {
        try await api.registerPerson(phone: randomPhone(), name: "Interview Test")
        let mePerson = try await api.myPerson()
        let me = try XCTUnwrap(mePerson)
        let inc = try await api.openIncident(personId: me.id, entryPoint: "report_swipe", callerE164: "+15555550199")
        XCTAssertEqual(inc.entryPoint, "report_swipe")
        XCTAssertEqual(inc.severityLevel, .unrated)
        XCTAssertNotEqual(inc.campaignId, 0, "the seeded scam number links to a campaign")

        try await api.saveAnswer(incidentId: inc.id, questionId: "q_identity", answer: "My phone company")
        try await api.saveAnswer(incidentId: inc.id, questionId: "q_ask", answer: "yes")
        let shared = try XCTUnwrap(InterviewScript.sharedAnswer(["personal_details"]))
        try await api.saveAnswer(incidentId: inc.id, questionId: "q_shared", answer: shared)
        try await api.saveAnswer(incidentId: inc.id, questionId: "q_secrecy", answer: "yes")
        try await api.saveAnswer(incidentId: inc.id, questionId: "q_help", answer: "yes")

        let afterList = try await api.myIncidents()
        let after = try XCTUnwrap(afterList.first { $0.id == inc.id })
        XCTAssertEqual(after.severityLevel, .high)
        XCTAssertEqual(after.sharedItems, ["personal_details"])
        XCTAssertEqual(after.claimedIdentity, "My phone company")
        XCTAssertEqual(after.status, "in_progress")

        let steps = try await api.myRecoverySteps().filter { $0.incidentId == inc.id }
        XCTAssertEqual(Set(steps.map(\.stepKey)), ["credit_freeze", "watch_statements"])
        for s in steps { XCTAssertNotEqual(RecoveryLibrary.shared.steps[s.stepKey], nil, "every step has vetted wording") }

        // mark_step_done: ticking every now/today step resolves the incident.
        for s in steps where s.priority != "this_week" { try await api.markStepDone(stepId: s.id, done: true) }
        let doneSteps = try await api.myRecoverySteps().filter { $0.incidentId == inc.id }
        XCTAssertTrue(doneSteps.first { $0.stepKey == "credit_freeze" }!.done)
        let resolvedList = try await api.myIncidents()
        let resolved = try XCTUnwrap(resolvedList.first { $0.id == inc.id })
        XCTAssertTrue(resolved.isResolved)
        XCTAssertTrue(resolved.resolvedAt.isSet)
    }

    func testCompanionIncidentAndSettingsRoundTrip() async throws {
        try await api.registerPerson(phone: randomPhone(), name: "Settings Test")
        let mePerson = try await api.myPerson()
        var me = try XCTUnwrap(mePerson)
        let inc = try await api.openIncident(personId: me.id, entryPoint: "companion")
        XCTAssertEqual(inc.status, "open")

        me.accessibilityMode = true
        me.familyCodeWord = "blue pancake"
        me.apnsToken = "abc123"
        try await api.updateSettings(me)
        let againPerson = try await api.myPerson()
        let again = try XCTUnwrap(againPerson)
        XCTAssertTrue(again.accessibilityMode)
        XCTAssertEqual(again.familyCodeWord, "blue pancake")
        XCTAssertEqual(again.apnsToken, "abc123")

        try await api.setSharingPaused(personId: me.id, paused: true)
        let paused = try await api.myPerson()
        XCTAssertEqual(paused?.sharingPaused, true)
    }

    func testPublicReadsAndReport() async throws {
        let labels = try await api.callerLabels()
        XCTAssertTrue(labels.contains { $0.value == "+15555550199" && $0.reporterCount >= 14 }, "\(labels)")
        let campaigns = try await api.campaigns()
        XCTAssertGreaterThanOrEqual(campaigns.count, 5)

        try await api.registerPerson(phone: randomPhone(), name: "Reporter")
        let mePerson = try await api.myPerson()
        let me = try XCTUnwrap(mePerson)
        try await api.reportValue(personId: me.id, kind: "number", value: "+15555550144")
        let checks = try await api.myChecks()
        let contacts = try await api.myContacts()
        let briefings = try await api.myBriefings()
        let pending = try await api.myPendingVerifications()
        XCTAssertTrue(checks.isEmpty)
        XCTAssertTrue(contacts.isEmpty)
        XCTAssertTrue(briefings.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }

    /// Recents report replay against the real module: twice → one incident, answers saved once, severity set.
    func testCallReportReplayAgainstModule() async throws {
        try await api.registerPerson(phone: randomPhone(), name: "Replay Test")
        let mePerson = try await api.myPerson()
        let me = try XCTUnwrap(mePerson)
        let store = CallReportStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString).json"))
        let report = CallReport(token: token, callerE164: "+15555550199",
                                answers: ["q_identity": "My bank", "q_ask": "yes", "q_shared": "nothing", "q_secrecy": "yes", "q_help": "no"],
                                reportedAt: Date())
        store.save(report)
        let first = await CallReportReplayer.replay(store: store, backend: api, token: token, personId: me.id)
        XCTAssertEqual(first.replayed, [report.requestKey], "\(first)")
        store.save(report)
        let second = await CallReportReplayer.replay(store: store, backend: api, token: token, personId: me.id)
        XCTAssertEqual(second.replayed, [report.requestKey])
        let incidents = try await api.myIncidents().filter { $0.requestKey == report.requestKey }
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?.entryPoint, "report_swipe")
        XCTAssertEqual(incidents.first?.answers["q_ask"], "yes")
        XCTAssertNotEqual(incidents.first?.severityLevel, .unrated)
        let again = try await api.openIncident(requestKey: report.requestKey, personId: me.id, entryPoint: "report_swipe",
                                               callerE164: "+15555550199")
        XCTAssertEqual(again.id, incidents.first?.id, "open_incident is idempotent by request_key")
        let requests = try await api.myAlertRequests()
        XCTAssertTrue(requests.isEmpty, "no family yet, so no reply requests")
    }
}
