import XCTest
@testable import KavachKit

// MARK: Fixtures

private func incident(_ id: UInt64, entry: String = "report_swipe", key: String = "k", caller: String = "+14155550199",
                      answers: [String: String] = [:], severity: String = "", status: String = "open",
                      at micros: Int64 = 1_700_000_000_000_000) -> Incident {
    Incident(id: id, requestKey: key, personId: 1, entryPoint: entry, callerE164: caller, claimedIdentity: "",
             answersJson: String(decoding: try! JSONEncoder().encode(answers), as: UTF8.self), tactics: [], sharedItems: [],
             severity: severity, status: status, familyAckBy: 0, campaignId: 0, createdAt: STTimestamp(micros: micros),
             resolvedAt: STTimestamp(micros: 0))
}

private actor RecordingBackend: CallReportBackend {
    var opened: [(key: String, entry: String, caller: String)] = []
    var reported: [String] = []
    var byKey: [String: Incident] = [:]
    private var nextId: UInt64 = 1

    func openIncident(requestKey: String, personId: UInt64, entryPoint: String, callerE164: String) async throws -> Incident {
        opened.append((requestKey, entryPoint, callerE164))
        if let i = byKey[requestKey] { return i } // idempotent like the module
        let i = incident(nextId, entry: entryPoint, key: requestKey, caller: callerE164)
        nextId += 1
        byKey[requestKey] = i
        return i
    }
    func saveAnswer(incidentId: UInt64, questionId: String, answer: String) async throws {}
    func reportValue(personId: UInt64, kind: String, value: String) async throws { reported.append("\(kind):\(value)") }
}

// MARK: Call ended → follow-up decision

final class CallFollowUpTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testIncomingConnectedCallThatEndsNotifiesOnce() {
        var t = CallFollowUpTracker()
        let id = UUID()
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false), companionOpen: false, now: t0), .none, "ringing")
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true), companionOpen: false, now: t0 + 5), .none)
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true, hasEnded: true),
                                 companionOpen: false, now: t0 + 120), .notify)
        XCTAssertTrue(t.showsPrompt(now: t0 + 130))
        // CallKit can report the same end twice: dedupe by UUID.
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true, hasEnded: true),
                                 companionOpen: false, now: t0 + 121), .none)
    }

    func testMissedIncomingCallStillCounts() {
        var t = CallFollowUpTracker()
        let id = UUID()
        _ = t.observe(.init(uuid: id, isOutgoing: false), companionOpen: false, now: t0)
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false, hasEnded: true), companionOpen: false, now: t0 + 20), .notify)
    }

    func testOutgoingCallsAreIgnored() {
        var t = CallFollowUpTracker()
        let id = UUID()
        _ = t.observe(.init(uuid: id, isOutgoing: true, hasConnected: true), companionOpen: false, now: t0)
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: true, hasConnected: true, hasEnded: true), companionOpen: false, now: t0 + 60), .none)
        XCTAssertFalse(t.showsPrompt(now: t0 + 61))
    }

    func testCompanionOpenHandlesTheEndWithoutAPrompt() {
        var t = CallFollowUpTracker()
        let id = UUID()
        _ = t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true), companionOpen: true, now: t0)
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true, hasEnded: true), companionOpen: true, now: t0 + 60),
                       .companionHandles)
        XCTAssertFalse(t.showsPrompt(now: t0 + 61), "no double prompt after Call Companion")
        // And it stays handled when the Companion closes.
        XCTAssertEqual(t.observe(.init(uuid: id, isOutgoing: false, hasEnded: true), companionOpen: false, now: t0 + 62), .none)
    }

    func testCallThatEndedWhileSuspendedPromptsOnHome() {
        var t = CallFollowUpTracker()
        let id = UUID()
        _ = t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true), companionOpen: false, now: t0)
        t.touchLive(now: t0 + 30) // app went to the background mid-call
        // Back 10 minutes later: the call is gone from CXCallObserver.calls.
        XCTAssertEqual(t.reconcile(current: [], companionOpen: false, now: t0 + 630), .prompt)
        XCTAssertTrue(t.showsPrompt(now: t0 + 640))
        XCTAssertEqual(t.reconcile(current: [], companionOpen: false, now: t0 + 700), .none, "once only")
    }

    func testOldSuspendedCallsAndLiveCallsDontPrompt() {
        var t = CallFollowUpTracker()
        let old = UUID(), live = UUID()
        _ = t.observe(.init(uuid: old, isOutgoing: false, hasConnected: true), companionOpen: false, now: t0)
        _ = t.observe(.init(uuid: live, isOutgoing: false, hasConnected: true), companionOpen: false, now: t0)
        let later = t0 + 31 * 60
        XCTAssertEqual(t.reconcile(current: [.init(uuid: live, isOutgoing: false, hasConnected: true)],
                                   companionOpen: false, now: later), .none,
                       "last seen over 30 min ago: too old; the other call is still going on")
        XCTAssertEqual(t.observe(.init(uuid: live, isOutgoing: false, hasConnected: true, hasEnded: true),
                                 companionOpen: false, now: later + 10), .notify, "long call refreshed by reconcile")
    }

    func testPromptExpiresAndClears() {
        var t = CallFollowUpTracker()
        _ = t.observe(.init(uuid: UUID(), isOutgoing: false, hasEnded: true), companionOpen: false, now: t0)
        XCTAssertTrue(t.showsPrompt(now: t0 + 29 * 60))
        XCTAssertFalse(t.showsPrompt(now: t0 + 31 * 60))
        t.clearPrompt()
        XCTAssertFalse(t.showsPrompt(now: t0))
    }

    func testPersistsAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "CallFollowUpTrackerTests")!
        defaults.removePersistentDomain(forName: "CallFollowUpTrackerTests")
        var t = CallFollowUpTracker()
        let id = UUID()
        _ = t.observe(.init(uuid: id, isOutgoing: false, hasConnected: true), companionOpen: false, now: t0)
        t.save(to: defaults)
        var loaded = CallFollowUpTracker.load(from: defaults)
        XCTAssertEqual(loaded, t)
        XCTAssertEqual(loaded.reconcile(current: [], companionOpen: false, now: t0 + 60), .prompt)
    }
}

// MARK: Report a call: incident creation + resume

final class ReportFlowTests: XCTestCase {
    func testDraftRequestKeyIsDeterministicAndFits() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let a = ReportDraft(personId: 7, callerE164: "+14155550199", startedAt: at)
        let b = ReportDraft(personId: 7, callerE164: "+14155550199", startedAt: at)
        let c = ReportDraft(personId: 7, callerE164: "", startedAt: at)
        XCTAssertEqual(a.requestKey, b.requestKey)
        XCTAssertNotEqual(a.requestKey, c.requestKey)
        XCTAssertTrue(a.requestKey.hasPrefix("ios-app-report-"))
        XCTAssertLessThanOrEqual(a.requestKey.count, 64, "module limit")
    }

    func testOpeningCreatesOneReportSwipeIncidentEvenWhenRetried() async throws {
        let backend = RecordingBackend()
        let draft = ReportDraft(personId: 7, callerE164: "+14155550199")
        let first = try await ReportFiling.open(draft, backend: backend)
        let again = try await ReportFiling.open(draft, backend: backend)
        XCTAssertEqual(first.id, again.id)
        let opened = await backend.opened
        XCTAssertEqual(opened.map(\.entry), ["report_swipe", "report_swipe"])
        XCTAssertEqual(Set(opened.map(\.key)), [draft.requestKey])
        XCTAssertEqual(opened.first?.caller, "+14155550199")
        XCTAssertEqual(ReportsList.source(of: first), .app, "in-app reports are labeled as such, not Recents")
    }

    func testFinishReportsTheNumberOnlyWhenGiven() async throws {
        let backend = RecordingBackend()
        try await ReportFiling.finish(personId: 7, callerE164: "", backend: backend)
        try await ReportFiling.finish(personId: 7, callerE164: "+14155550199", backend: backend)
        let reported = await backend.reported
        XCTAssertEqual(reported, ["number:+14155550199"])
    }

    func testResumesAtFirstUnansweredQuestion() {
        XCTAssertEqual(ReportsList.firstUnanswered([:]), 0)
        XCTAssertEqual(ReportsList.firstUnanswered(["q_identity": "My bank"]), 1)
        XCTAssertEqual(ReportsList.firstUnanswered(["q_identity": "My bank", "q_ask": "yes"]), 2)
        XCTAssertEqual(ReportsList.firstUnanswered(["q_identity": "My bank", "q_ask": "yes", "q_shared": "nothing",
                                                    "q_secrecy": "no"]), 4)
        XCTAssertNil(ReportsList.firstUnanswered(["q_identity": "x", "q_ask": "no", "q_shared": "nothing",
                                                  "q_secrecy": "no", "q_help": "no"]))
        // Extra keys don't count as interview answers.
        XCTAssertEqual(ReportsList.firstUnanswered(["q_engaged": "no", "q_summary": "provided"]), 0)
    }

    func testCallerReputationIsRedOnlyForLikelyScam() {
        let labels = [CallerLabel(value: "+14155550199", reporterCount: 4), CallerLabel(value: "+14155550100", reporterCount: 2)]
        let scam = CallerReputation(e164: "+14155550199", labels: labels)
        XCTAssertEqual(scam?.text, "4 people have reported this number as a scam")
        XCTAssertEqual(scam?.isLikelyScam, true)
        XCTAssertEqual(CallerReputation(e164: "+14155550100", labels: labels)?.isLikelyScam, false)
        XCTAssertNil(CallerReputation(e164: "+14155550111", labels: labels))
        XCTAssertNil(CallerReputation(e164: "", labels: labels))
        XCTAssertEqual(CallerReputation(e164: "+1", labels: [CallerLabel(value: "+1", reporterCount: 1)])?.text,
                       "1 person has reported this number as a scam")
    }
}

// MARK: Your reports list

final class ReportsListTests: XCTestCase {
    func testMapsEveryEntryPointNewestFirst() {
        let list = ReportsList.make([
            incident(1, entry: "companion", key: "uuid-1", caller: "", at: 1_000),
            incident(2, entry: "report_swipe", key: "ios-report-abc", at: 5_000),
            incident(3, entry: "report_swipe", key: "callrep-abc", at: 4_000),
            incident(4, entry: "report_swipe", key: "ios-app-report-abc", at: 3_000),
            incident(5, entry: "imessage", key: "x", caller: "", at: 2_000),
            incident(6, entry: "app", key: "y", caller: "", at: 6_000),
        ])
        XCTAssertEqual(list.map(\.id), [6, 2, 3, 4, 5, 1])
        XCTAssertEqual(list.map(\.source.label), ["Reported from the app", "From Recents", "From Recents",
                                                  "Reported from the app", "By text", "During a call"])
        XCTAssertEqual(list[1].callerText, "+1 (415) 555-0199")
        XCTAssertEqual(list[0].callerText, "Number not given")
        XCTAssertFalse(list[0].hasCaller)
    }

    func testStatusAndUnfinishedFilter() {
        let partial = incident(1, answers: ["q_identity": "My bank", "q_ask": "yes"])
        let answered = incident(2, answers: ["q_identity": "x", "q_ask": "no", "q_shared": "nothing", "q_secrecy": "no", "q_help": "no"],
                                severity: "low")
        let resolved = incident(3, status: "resolved")
        let rows = ReportsList.make([partial, answered, resolved])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId[1]?.status, .unfinished)
        XCTAssertEqual(byId[1]?.resumeIndex, 2)
        XCTAssertEqual(byId[2]?.status, .open)
        XCTAssertEqual(byId[2]?.severity, .low)
        XCTAssertNil(byId[2]?.resumeIndex)
        XCTAssertEqual(byId[3]?.status, .resolved, "a resolved report is never 'unfinished'")
        XCTAssertEqual(ReportsList.unfinished([partial, answered, resolved]).map(\.id), [1])
    }

    func testAnswerSummaryUsesTheWordsThePersonChose() {
        let lines = ReportsList.answerLines(["q_identity": "My bank", "q_ask": "agreed", "q_shared": "code,gift_card",
                                             "q_help": "yes"])
        XCTAssertEqual(lines.map(\.questionId), ["q_identity", "q_ask", "q_shared", "q_help"])
        XCTAssertEqual(lines[0].answer, "My bank")
        XCTAssertEqual(lines[1].answer, "Yes, and I agreed to pay or call back")
        XCTAssertEqual(lines[2].answer, "A code sent to my phone; Gift card numbers")
        XCTAssertEqual(lines[3].answer, "Yes, please")
        XCTAssertEqual(lines[2].title, "What you shared")
    }

    func testAccessibilityTextNamesCallerSourceLevelAndStatus() {
        let r = ReportSummary(incident(1, key: "ios-report-1"))
        XCTAssertTrue(r.accessibilityText.hasPrefix("Call from +1 (415) 555-0199. From Recents."))
        XCTAssertTrue(r.accessibilityText.hasSuffix("Level: Not rated yet. Not finished"))
    }
}

// MARK: Forward to Kavach by text

final class ForwardToKavachTests: XCTestCase {
    func testWrapperFormat() {
        XCTAssertEqual(ForwardToKavach.wrap("Your package is held. Pay $2 at http://x.co"),
                       "Forwarded message:\n\u{201C}Your package is held. Pay $2 at http://x.co\u{201D}")
        XCTAssertEqual(ForwardToKavach.wrap("  Hi grandma  ", from: "+1 (415) 555-0199"),
                       "Forwarded message:\nFrom: +1 (415) 555-0199\n\u{201C}Hi grandma\u{201D}")
        XCTAssertEqual(ForwardToKavach.wrap("x", from: " "), "Forwarded message:\n\u{201C}x\u{201D}", "blank sender is left out")
        // Straight quotes inside stay as they are; the curly quotes delimit the message.
        XCTAssertEqual(ForwardToKavach.wrap(#"He said "send the code""#),
                       "Forwarded message:\n\u{201C}He said \"send the code\"\u{201D}")
    }

    func testMessagesURLEncodesTheWrappedBody() throws {
        let msg = "Pay now & win = prize #1 + more"
        let url = try XCTUnwrap(ForwardToKavach.messagesURL(number: "+1 (415) 610-6180", message: msg))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("sms:+14156106180&body="))
        let encoded = String(s.dropFirst("sms:+14156106180&body=".count))
        XCTAssertFalse(encoded.contains("&") || encoded.contains("#") || encoded.contains("+") || encoded.contains("\n"))
        XCTAssertEqual(encoded.removingPercentEncoding, ForwardToKavach.wrap(msg))
        XCTAssertNil(ForwardToKavach.messagesURL(number: "", message: msg))
    }

    func testHelpSentence() {
        XCTAssertEqual(ForwardToKavach.helpText(),
                       "When you forward a message, start it with Forwarded message: so Kavach knows you received it.")
    }
}

// MARK: Live: Report a call against the local SpacetimeDB (skipped when unreachable)

final class ReportFlowLiveTests: XCTestCase {
    func testReportCallCreatesIncidentResumesAndFilesNumber() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["KAVACH_TEST_SPACETIME_URL"] ?? "http://127.0.0.1:3000")!
        let db = SpacetimeClient(baseURL: url, database: env["KAVACH_TEST_DB"] ?? "kavach-ios")
        let token: String
        do { token = try await db.newIdentity().token } catch { throw XCTSkip("SpacetimeDB not reachable at \(url)") }
        let api = KavachAPI(db: db, agents: AgentClient(baseURL: URL(string: "http://127.0.0.1:9")!), token: token)
        try await api.registerPerson(phone: "+1555555" + String(format: "%04d", Int.random(in: 1_000...9_999)), name: "Report Test")
        let person = try await api.myPerson()
        let me = try XCTUnwrap(person)
        let caller = "+1555" + String(format: "%07d", Int.random(in: 1_000_000...9_999_999))

        let draft = ReportDraft(personId: me.id, callerE164: caller)
        let inc = try await ReportFiling.open(draft, backend: api)
        _ = try await ReportFiling.open(draft, backend: api) // retry: same incident
        XCTAssertEqual(inc.entryPoint, "report_swipe")
        XCTAssertEqual(inc.callerE164, caller)

        // Quit after two answers: the list shows it unfinished, resuming at question 3.
        try await api.saveAnswer(incidentId: inc.id, questionId: "q_identity", answer: "My bank")
        try await api.saveAnswer(incidentId: inc.id, questionId: "q_ask", answer: "yes")
        var mine = try await api.myIncidents()
        XCTAssertEqual(mine.filter { $0.requestKey == draft.requestKey }.count, 1)
        var row = try XCTUnwrap(ReportsList.make(mine).first { $0.id == inc.id })
        XCTAssertEqual(row.status, .unfinished)
        XCTAssertEqual(row.resumeIndex, 2)
        XCTAssertEqual(row.source, .app)

        for (q, a) in [("q_shared", "nothing"), ("q_secrecy", "yes"), ("q_help", "no")] {
            try await api.saveAnswer(incidentId: inc.id, questionId: q, answer: a)
        }
        try await ReportFiling.finish(personId: me.id, callerE164: caller, backend: api)
        mine = try await api.myIncidents()
        row = try XCTUnwrap(ReportsList.make(mine).first { $0.id == inc.id })
        XCTAssertEqual(row.status, .open)
        XCTAssertNil(row.resumeIndex)
        XCTAssertNotEqual(row.severity, .unrated, "the module rated it")
    }
}
