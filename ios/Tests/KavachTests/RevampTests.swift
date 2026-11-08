import Contacts
import XCTest
@testable import KavachKit

// MARK: Fixtures

private func ts(_ d: Date) -> STTimestamp { STTimestamp(date: d) }
private let unset = STTimestamp(micros: 0)

private func contact(_ id: UInt64, _ name: String, phone: String = "+15555550100", emergency: Bool = false,
                     consent: String = "accepted") -> Contact {
    Contact(id: id, personId: 1, name: name, phoneE164: phone, relationship: "Grandson", channel: "imessage",
            isEmergencyContact: emergency, isAppUser: false, linkedPersonId: 0, consentStatus: consent)
}

private let tommy = contact(10, "Tommy Rivera", phone: "+15125550142")
private let maria = contact(11, "Maria Lopez", phone: "+15125550177", emergency: true)
private let family = [tommy, maria]

// MARK: Alert requests

final class AlertRequestTests: XCTestCase {
    func testDecodesMyAlertRequestsRow() throws {
        let names = ["id", "person_id", "incident_id", "verification_id", "kind", "recipient_contact_ids", "status",
                     "acked_by_contact_id", "reminders_sent", "last_body", "created_at", "deadline", "resolved_at"]
        let elements = names.map { #"{"name":{"some":"\#($0)"}}"# }.joined(separator: ",")
        let json = #"[{"schema":{"elements":[\#(elements)]},"rows":[[4,1,7,0,"help",[10,11],"pending",0,1,"Joe asked for help.",[1794135650335796],[1794135710335796],[0]],[5,1,8,0,"alert",[10],"acknowledged",10,0,"",[1794135650335796],[0],[1794135890335796]]]}]"#
        let rows = try SQLDecoder.decode(AlertRequest.self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].recipientContactIds, [10, 11])
        XCTAssertEqual(rows[0].remindersSent, 1)
        XCTAssertEqual(rows[0].kindValue, .help)
        XCTAssertEqual(rows[0].phase, .reminded)
        XCTAssertTrue(rows[0].isUrgent)
        XCTAssertEqual(rows[1].phase, .acknowledged)
        XCTAssertEqual(rows[1].ackedByContactId, 10)
        XCTAssertFalse(rows[1].resolvedAt.micros == 0)
    }

    func testStatusTextForEveryPhase() {
        let now = Date()
        var r = AlertRequest(id: 1, incidentId: 7, kind: "help", recipientContactIds: [10, 11], status: "pending", createdAt: ts(now))
        XCTAssertEqual(FamilyReplies.headline(r, contacts: family), "Waiting for Tommy and Maria to reply…")
        r.remindersSent = 1
        XCTAssertEqual(FamilyReplies.headline(r, contacts: family), "No reply yet from Tommy and Maria. Call Maria.",
                       "the emergency contact among the recipients is the one to call")
        r.status = "unanswered"
        XCTAssertEqual(FamilyReplies.headline(r, contacts: family), "No reply from your family. Call Maria.")
        XCTAssertEqual(FamilyReplies.detail(r), "Please call them yourself now.")
        r.status = "acknowledged"; r.ackedByContactId = 10
        XCTAssertEqual(FamilyReplies.headline(r, contacts: family), "Tommy saw it")
        XCTAssertFalse(r.isUrgent)

        let v = AlertRequest(id: 2, kind: "verify", recipientContactIds: [10], status: "pending", createdAt: ts(now))
        XCTAssertEqual(FamilyReplies.headline(v, contacts: family), "Waiting for Tommy to confirm…")
    }

    func testJoinNames() {
        XCTAssertEqual(FamilyReplies.joinNames([]), "your family")
        XCTAssertEqual(FamilyReplies.joinNames(["Tommy"]), "Tommy")
        XCTAssertEqual(FamilyReplies.joinNames(["Tommy", "Maria"]), "Tommy and Maria")
        XCTAssertEqual(FamilyReplies.joinNames(["Tommy", "Maria", "Sam"]), "Tommy, Maria and Sam")
    }

    func testCompanionProgressToldThenSeen() {
        XCTAssertEqual(FamilyReplies.progress(for: nil, contacts: family, sharingPaused: true).text,
                       "Family alerts are paused, so your family wasn't told.")
        var r = AlertRequest(id: 1, incidentId: 7, kind: "help", recipientContactIds: [10], status: "pending", createdAt: ts(Date()))
        let told = FamilyReplies.progress(for: r, contacts: family, sharingPaused: false)
        XCTAssertTrue(told.told); XCTAssertNil(told.seenBy)
        XCTAssertEqual(told.text, "Told Tommy. Waiting for a reply…")
        r.status = "acknowledged"; r.ackedByContactId = 10
        let seen = FamilyReplies.progress(for: r, contacts: family, sharingPaused: false)
        XCTAssertEqual(seen.seenBy, "Tommy")
        XCTAssertEqual(seen.text, "Tommy saw it and knows you asked for help.")
    }

    func testRelevantKeepsOpenAndRecentAcksUrgentFirst() {
        let now = Date()
        let waiting = AlertRequest(id: 1, kind: "help", recipientContactIds: [10], status: "pending", createdAt: ts(now.addingTimeInterval(-60)))
        let unanswered = AlertRequest(id: 2, kind: "alert", recipientContactIds: [10], status: "unanswered", createdAt: ts(now.addingTimeInterval(-600)))
        let oldAck = AlertRequest(id: 3, kind: "help", recipientContactIds: [10], status: "acknowledged", ackedByContactId: 10,
                                  createdAt: ts(now.addingTimeInterval(-7200)), resolvedAt: ts(now.addingTimeInterval(-7000)))
        let freshAck = AlertRequest(id: 4, kind: "help", recipientContactIds: [10], status: "acknowledged", ackedByContactId: 10,
                                    createdAt: ts(now.addingTimeInterval(-300)), resolvedAt: ts(now.addingTimeInterval(-120)))
        let stale = AlertRequest(id: 5, kind: "help", recipientContactIds: [10], status: "pending", createdAt: ts(now.addingTimeInterval(-90_000)))
        XCTAssertEqual(FamilyReplies.relevant([waiting, unanswered, oldAck, freshAck, stale], now: now).map(\.id), [2, 1, 4])
    }

    func testMemberStatusAndResponseStats() {
        let now = Date()
        let a = AlertRequest(id: 1, kind: "help", recipientContactIds: [10, 11], status: "acknowledged", ackedByContactId: 10,
                             createdAt: ts(now.addingTimeInterval(-600)), resolvedAt: ts(now.addingTimeInterval(-360)))
        let b = AlertRequest(id: 2, kind: "alert", recipientContactIds: [11], status: "unanswered",
                             createdAt: ts(now.addingTimeInterval(-300)))
        XCTAssertEqual(FamilyReplies.memberStatus(tommy, in: [a, b]), .replied)
        XCTAssertEqual(FamilyReplies.memberStatus(maria, in: [a, b]), .noReply)
        XCTAssertEqual(FamilyReplies.memberStatus(contact(12, "Sam"), in: [a, b]), .none)
        let s = FamilyReplies.stats([a, b])
        XCTAssertEqual(s.asked, 2); XCTAssertEqual(s.answered, 1); XCTAssertEqual(s.unanswered, 1)
        XCTAssertEqual(s.medianMinutes, 4)
        XCTAssertEqual(s.rate, 0.5)
    }
}

// MARK: Phone numbers

final class PhoneNumberTests: XCTestCase {
    func testE164NormalizationUSDefault() {
        XCTAssertEqual(PhoneNumbers.e164("(512) 555-0142"), "+15125550142")
        XCTAssertEqual(PhoneNumbers.e164("512.555.0142"), "+15125550142")
        XCTAssertEqual(PhoneNumbers.e164("1 (512) 555-0142"), "+15125550142")
        XCTAssertEqual(PhoneNumbers.e164("+1 512 555 0142"), "+15125550142")
        XCTAssertEqual(PhoneNumbers.e164("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(PhoneNumbers.e164("011 44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(PhoneNumbers.e164("0044 20 7946 0958"), "+442079460958")
        XCTAssertEqual(PhoneNumbers.e164("(512) 555-0142 ext. 12"), "+15125550142")
        XCTAssertEqual(PhoneNumbers.e164("512-555-0142 x7"), "+15125550142")
        XCTAssertEqual(PhoneNumbers.e164("\u{00A0}512\u{2011}555\u{2011}0142 "), "+15125550142")
    }

    func testRejectsUnusableNumbers() {
        XCTAssertNil(PhoneNumbers.e164(""))
        XCTAssertNil(PhoneNumbers.e164("555-0142"), "7 digits has no area code")
        XCTAssertNil(PhoneNumbers.e164("+1234"))
        XCTAssertNil(PhoneNumbers.e164("hello"))
        XCTAssertEqual(normalizePhone("555-0142"), "")
    }

    func testFormatting() {
        XCTAssertEqual(PhoneNumbers.formatted("+15125550142"), "+1 (512) 555-0142")
        XCTAssertEqual(PhoneNumbers.formatted("+442079460958"), "+442079460958")
    }
}

// MARK: Contacts → family

final class FamilyContactMappingTests: XCTestCase {
    private func cn(_ given: String, _ family: String = "", nickname: String = "",
                    phones: [(String, String)], relations: [(String, String)] = []) -> CNMutableContact {
        let c = CNMutableContact()
        c.givenName = given; c.familyName = family; c.nickname = nickname
        c.phoneNumbers = phones.map { CNLabeledValue(label: $0.0, value: CNPhoneNumber(stringValue: $0.1)) }
        c.contactRelations = relations.map { CNLabeledValue(label: $0.0, value: CNContactRelation(name: $0.1)) }
        return c
    }

    func testDraftPutsMobileFirstAndDefaultsToIMessage() throws {
        let c = cn("Tommy", "Rivera", phones: [(CNLabelWork, "512-555-0188"), (CNLabelPhoneNumberiPhone, "(512) 555-0142"),
                                               (CNLabelHome, "512 555 0142")])
        let d = try XCTUnwrap(FamilyContactMapper.draft(from: c))
        XCTAssertEqual(d.name, "Tommy Rivera")
        XCTAssertEqual(d.phones.map(\.e164), ["+15125550142", "+15125550188"], "mobile first, duplicates dropped")
        XCTAssertEqual(d.phoneE164, "+15125550142")
        XCTAssertEqual(d.channel, .imessage)
        XCTAssertFalse(d.isEmergencyContact)
        XCTAssertEqual(d.contactIdentifier, c.identifier)
        XCTAssertTrue(d.isValid)
    }

    func testNoUsableNumberMeansNoDraft() {
        XCTAssertNil(FamilyContactMapper.draft(from: cn("Bad", phones: [(CNLabelHome, "555-0142")])))
    }

    func testRelationshipFromNicknameNameAndLabels() {
        XCTAssertEqual(FamilyContactMapper.guessedRelationship(cn("Sam", nickname: "Grandson", phones: [])), "Grandson")
        XCTAssertEqual(FamilyContactMapper.guessedRelationship(cn("Tommy (grandson)", phones: [])), "Grandson")
        XCTAssertEqual(FamilyContactMapper.guessedRelationship(cn("Mom", phones: [])), "Mother")
        XCTAssertNil(FamilyContactMapper.guessedRelationship(cn("Dr", "Patel", phones: [])))
        XCTAssertEqual(FamilyContactMapper.relationship(fromContactLabel: CNLabelContactRelationSon), "Son")
        XCTAssertEqual(FamilyContactMapper.relationship(fromContactLabel: CNLabelContactRelationDaughter), "Daughter")
    }

    func testSuggestionsFromRelationsAndNamesExcludeExistingFamily() {
        let me = cn("Joe", "Rivera", phones: [(CNLabelPhoneNumberiPhone, "5125550101")],
                    relations: [(CNLabelContactRelationSon, "Carlos Rivera"), (CNLabelContactRelationDaughter, "Ana")])
        let carlos = cn("Carlos", "Rivera", phones: [(CNLabelPhoneNumberMobile, "5125550111")])
        let ana = cn("Ana", "Rivera", phones: [(CNLabelPhoneNumberMobile, "5125550122")])
        let neighbor = cn("Bob", nickname: "Neighbor", phones: [(CNLabelPhoneNumberMobile, "5125550133")])
        let tommyCN = cn("Tommy", nickname: "Grandson", phones: [(CNLabelPhoneNumberMobile, "5125550142")])
        let stranger = cn("Pat", "Lee", phones: [(CNLabelPhoneNumberMobile, "5125550199")])
        let s = FamilyContactMapper.suggestions(from: [me, carlos, ana, neighbor, tommyCN, stranger],
                                                excludingPhones: ["+15125550142"])
        XCTAssertEqual(s.map(\.name), ["Ana Rivera", "Carlos Rivera", "Bob"], "family first, then others; Tommy already added")
        XCTAssertEqual(s.first { $0.name == "Carlos Rivera" }?.relationship, "Son")
        XCTAssertEqual(s.first { $0.name == "Ana Rivera" }?.draft.relationship, "Daughter")
        XCTAssertEqual(s.first { $0.name == "Bob" }?.relationship, "Neighbor")
    }

    func testNameSyncOnlyFollowsChangesInContacts() {
        // First link: remember the Contacts name, don't overwrite what the person typed.
        XCTAssertEqual(ContactNameSync.decide(savedName: "Tommy", contactsName: "Thomas Rivera", baseline: nil),
                       .init(update: nil, baseline: "Thomas Rivera"))
        // Unchanged in Contacts: nothing to do, even though the saved name differs.
        XCTAssertEqual(ContactNameSync.decide(savedName: "Tommy", contactsName: "Thomas Rivera", baseline: "Thomas Rivera"),
                       .init(update: nil, baseline: "Thomas Rivera"))
        // Renamed in Contacts: update.
        XCTAssertEqual(ContactNameSync.decide(savedName: "Tommy Rivera", contactsName: "Tommy Rivera-Lopez", baseline: "Tommy Rivera"),
                       .init(update: "Tommy Rivera-Lopez", baseline: "Tommy Rivera-Lopez"))
        // Renamed to what's already saved: no write.
        XCTAssertEqual(ContactNameSync.decide(savedName: "Tom", contactsName: "Tom", baseline: "Tommy"),
                       .init(update: nil, baseline: "Tom"))
    }
}

// MARK: Call reports (Recents)

private actor FakeBackend: CallReportBackend {
    var incidents: [String: Incident] = [:]
    var saved: [(UInt64, String, String)] = []
    var reported: [String] = []
    var failOpen = false

    func setFailOpen(_ v: Bool) { failOpen = v }
    func preload(_ key: String, answers: [String: String]) {
        incidents[key] = Self.incident(id: 99, key: key, answers: answers)
    }

    static func incident(id: UInt64, key: String, answers: [String: String]) -> Incident {
        Incident(id: id, requestKey: key, personId: 1, entryPoint: "report_swipe", callerE164: "+15555550199", claimedIdentity: "",
                 answersJson: String(decoding: try! JSONEncoder().encode(answers), as: UTF8.self), tactics: [], sharedItems: [],
                 severity: "", status: "open", familyAckBy: 0, campaignId: 0, createdAt: STTimestamp(micros: 1),
                 resolvedAt: STTimestamp(micros: 0))
    }

    func openIncident(requestKey: String, personId: UInt64, entryPoint: String, callerE164: String) async throws -> Incident {
        if failOpen { throw KavachError.transport("offline") }
        if let i = incidents[requestKey] { return i }
        let i = Self.incident(id: UInt64(incidents.count + 1), key: requestKey, answers: [:])
        incidents[requestKey] = i
        return i
    }

    func saveAnswer(incidentId: UInt64, questionId: String, answer: String) async throws {
        saved.append((incidentId, questionId, answer))
        if let (k, inc) = incidents.first(where: { $0.value.id == incidentId }) {
            var a = inc.answers; a[questionId] = answer
            incidents[k] = Self.incident(id: inc.id, key: k, answers: a)
        }
    }

    func reportValue(personId: UInt64, kind: String, value: String) async throws { reported.append(value) }
}

final class CallReportTests: XCTestCase {
    private let answers = ["q_identity": "My bank", "q_ask": "yes", "q_shared": "nothing", "q_secrecy": "yes", "q_help": "no"]

    private func tempStore() -> CallReportStore {
        CallReportStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString).json"))
    }

    func testUserInfoMatchesContract() throws {
        let at = Date(timeIntervalSince1970: 1_794_135_650)
        let r = CallReport(token: "tok", callerE164: "+15555550199", answers: answers, reportedAt: at)
        let info = r.userInfo
        XCTAssertEqual(info["token"] as? String, "tok")
        XCTAssertEqual(info["caller_e164"] as? String, "+15555550199")
        XCTAssertEqual(info["answers"] as? [String: String], answers)
        XCTAssertEqual(info["reported_at"] as? Int64, 1_794_135_650_000_000)
        XCTAssertEqual(info["request_key"] as? String, r.requestKey)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(info), "iOS sends userInfo as JSON")
        XCTAssertTrue(r.requestKey.hasPrefix("ios-report-"))
        XCTAssertLessThanOrEqual(r.requestKey.count, 64, "open_incident caps request_key at 64")
        XCTAssertEqual(r.requestKey, CallReport(token: "other", callerE164: "+15555550199", answers: [:], reportedAt: at).requestKey,
                       "deterministic from caller + time, so the service can derive the same key")
        XCTAssertNotEqual(r.requestKey, CallReport(token: "tok", callerE164: "+15555550188", answers: [:], reportedAt: at).requestKey)
        XCTAssertEqual(r.orderedAnswers.map(\.0), ["q_identity", "q_ask", "q_shared", "q_secrecy", "q_help"])
    }

    func testStoreRoundTripAndDedupe() {
        let store = tempStore()
        let r = CallReport(token: "tok", callerE164: "+15555550199", answers: answers, reportedAt: Date())
        store.save(r); store.save(r)
        XCTAssertEqual(store.pending(), [r])
        store.remove(requestKey: r.requestKey)
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testReplayIsIdempotent() async {
        let store = tempStore()
        let backend = FakeBackend()
        let r = CallReport(token: "tok", callerE164: "+15555550199", answers: answers, reportedAt: Date())
        store.save(r)

        let first = await CallReportReplayer.replay(store: store, backend: backend, token: "tok", personId: 1)
        XCTAssertEqual(first.replayed, [r.requestKey])
        let saved1 = await backend.saved.count
        XCTAssertEqual(saved1, 5)
        XCTAssertTrue(store.pending().isEmpty, "replayed reports leave the queue")

        // The same report again (e.g. saved twice): same incident, no answers re-saved.
        store.save(r)
        let second = await CallReportReplayer.replay(store: store, backend: backend, token: "tok", personId: 1)
        XCTAssertEqual(second.replayed, [r.requestKey])
        let (incCount, saved2, reported) = await (backend.incidents.count, backend.saved.count, backend.reported)
        XCTAssertEqual(incCount, 1)
        XCTAssertEqual(saved2, 5)
        XCTAssertEqual(reported, ["+15555550199", "+15555550199"], "report_number is idempotent per voter in the module")
    }

    func testReplaySkipsAnswersTheServiceAlreadySaved() async {
        let store = tempStore()
        let backend = FakeBackend()
        let r = CallReport(token: "tok", callerE164: "+15555550199", answers: answers, reportedAt: Date())
        await backend.preload(r.requestKey, answers: answers) // iOS's POST arrived
        store.save(r)
        _ = await CallReportReplayer.replay(store: store, backend: backend, token: "tok", personId: 1)
        let saved = await backend.saved.count
        XCTAssertEqual(saved, 0)
    }

    func testFailuresStayQueuedAndOtherSignInsAreDropped() async {
        let store = tempStore()
        let backend = FakeBackend()
        await backend.setFailOpen(true)
        let mine = CallReport(token: "tok", callerE164: "+15555550199", answers: answers, reportedAt: Date())
        let old = CallReport(token: "old-token", callerE164: "+15555550188", answers: answers, reportedAt: Date())
        store.save(mine); store.save(old)
        let out = await CallReportReplayer.replay(store: store, backend: backend, token: "tok", personId: 1)
        XCTAssertEqual(out.failed, [mine.requestKey])
        XCTAssertEqual(store.pending(), [mine])
    }
}

// MARK: Dashboard

final class NetworkDashboardTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private let now = Date(timeIntervalSince1970: 1_794_135_650) // a fixed "today"

    private func check(_ id: UInt64, _ verdict: String, daysAgo: Double, campaign: UInt64 = 0) -> MessageCheck {
        MessageCheck(id: id, requestKey: "k\(id)", personId: 1, source: "app_paste", contentRedacted: "…", verdict: verdict,
                     reason: "Reason \(id)", campaignId: campaign, evidenceCount: 0, createdAt: ts(now.addingTimeInterval(-daysAgo * 86_400)))
    }

    private func incident(_ id: UInt64, severity: String, daysAgo: Double, campaign: UInt64 = 0) -> Incident {
        Incident(id: id, requestKey: "i\(id)", personId: 1, entryPoint: "companion", callerE164: "", claimedIdentity: "My bank",
                 answersJson: "{}", tactics: [], sharedItems: [], severity: severity, status: "in_progress", familyAckBy: 0,
                 campaignId: campaign, createdAt: ts(now.addingTimeInterval(-daysAgo * 86_400)), resolvedAt: unset)
    }

    private func campaign(_ id: UInt64, _ title: String, reports: UInt32) -> Campaign {
        Campaign(id: id, slug: "c\(id)", title: title, tacticSummary: "", sampleText: "", weeklyReports: reports)
    }

    func testAggregatesKPIsDaysAndNetwork() {
        let checks = [check(1, "likely_scam", daysAgo: 0, campaign: 2), check(2, "safe", daysAgo: 0), check(3, "suspicious", daysAgo: 1),
                      check(4, "likely_scam", daysAgo: 3, campaign: 2), check(5, "likely_scam", daysAgo: 10)]
        let incidents = [incident(20, severity: "medium", daysAgo: 2, campaign: 3), incident(21, severity: "critical", daysAgo: 1)]
        let requests = [
            AlertRequest(id: 1, kind: "help", recipientContactIds: [10], status: "acknowledged", ackedByContactId: 10,
                         createdAt: ts(now.addingTimeInterval(-3600)), resolvedAt: ts(now.addingTimeInterval(-3300))),
            AlertRequest(id: 2, kind: "alert", recipientContactIds: [11], status: "unanswered", createdAt: ts(now.addingTimeInterval(-1800))),
        ]
        let campaigns = [campaign(1, "Fake job offers", reports: 40), campaign(2, "Unpaid toll texts", reports: 20),
                         campaign(3, "Bank fraud calls", reports: 10), campaign(4, "Prize scams", reports: 5),
                         campaign(5, "Gift card scams", reports: 2)]
        let d = NetworkDashboard(checks: checks, incidents: incidents, alertRequests: requests, contacts: family,
                                 campaigns: campaigns, briefings: [], now: now, calendar: cal)

        XCTAssertEqual(d.messagesChecked, 4, "only the last 7 days")
        XCTAssertEqual(d.scamsStopped, 3, "2 likely-scam messages + 1 medium call")
        XCTAssertEqual(d.communityReports, 77)
        XCTAssertEqual(d.response.asked, 2)
        XCTAssertEqual(d.responseRateText, "50%")
        XCTAssertEqual(d.responseDetail, "1 of 2 answered · usually in 5 min")

        XCTAssertEqual(d.days.count, 7)
        XCTAssertEqual(d.days.last?.start, cal.startOfDay(for: now))
        XCTAssertEqual(d.days.last.map { [$0.safe, $0.suspicious, $0.likelyScam] }, [1, 0, 1])
        XCTAssertEqual(d.days.reduce(0) { $0 + $1.total }, 4)
        XCTAssertEqual(d.weekSummary, "1 looked safe, 1 suspicious, 2 likely scam.")

        XCTAssertEqual(d.family.map(\.status), [.replied, .noReply])
        XCTAssertEqual(d.threats.count, 5, "3 non-safe messages this week + 2 calls")
        XCTAssertEqual(d.threats.first?.id, "check-1", "newest first")
        XCTAssertTrue(d.threats.contains { $0.id == "incident-21" && $0.isSevere })
        XCTAssertEqual(d.campaigns.map(\.id), [2, 3, 1, 4], "linked campaigns first, then most reported; max 4")
        XCTAssertEqual(d.campaigns.first?.linkedThreats, 2)
        XCTAssertEqual(d.campaigns.first { $0.id == 1 }?.weight, 1)
        XCTAssertEqual(d.incidents.map(\.id), [21, 20])
    }

    func testEmptyState() {
        let d = NetworkDashboard(checks: [], incidents: [], alertRequests: [], contacts: [], campaigns: [], briefings: [], now: now, calendar: cal)
        XCTAssertEqual(d.messagesChecked, 0)
        XCTAssertEqual(d.responseRateText, "–")
        XCTAssertEqual(d.responseDetail, "No requests yet")
        XCTAssertEqual(d.weekSummary, "No messages checked in the last 7 days.")
        XCTAssertTrue(d.threats.isEmpty)
    }
}

// MARK: Feedback

final class VerdictFeedbackTests: XCTestCase {
    func testFeedbackBodies() throws {
        func obj(_ b: [String: JSONValue]) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        }
        let right = try obj(VerdictFeedback(verdict: .likelyScam, choice: .right).body(checkId: 12, requestKey: "rk"))
        XCTAssertEqual(right["correct"] as? Bool, true)
        XCTAssertEqual(right["label"] as? String, "likely_scam")
        XCTAssertEqual(right["check_id"] as? Int, 12)
        XCTAssertEqual(right["request_key"] as? String, "rk")

        let wasSafe = try obj(VerdictFeedback(verdict: .suspicious, choice: .wasSafe).body(checkId: nil, requestKey: nil))
        XCTAssertEqual(wasSafe["correct"] as? Bool, false)
        XCTAssertEqual(wasSafe["label"] as? String, "safe")
        XCTAssertNil(wasSafe["check_id"])

        let wasScam = try obj(VerdictFeedback(verdict: .likelyScam, choice: .wasScam).body(checkId: 0, requestKey: ""))
        XCTAssertEqual(wasScam["correct"] as? Bool, true)
        XCTAssertNil(wasScam["check_id"], "0 means no id")
    }

    func testCheckResultCarriesIds() throws {
        let r = try AgentClient.decoder.decode(CheckResult.self, from: Data(#"{"verdict":"safe","reason":"ok","check_id":7}"#.utf8))
        XCTAssertEqual(r.checkId, 7)
        XCTAssertNil(r.requestKey)
    }
}
