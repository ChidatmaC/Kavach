import XCTest
@testable import KavachKit

private func ts(_ d: Date) -> STTimestamp { STTimestamp(date: d) }

final class ReportSectionTests: XCTestCase {
    private func inc(_ id: UInt64, answers: [String: String], status: String, minutesAgo: Double) -> Incident {
        Incident(id: id, requestKey: "k\(id)", personId: 1, entryPoint: "report_swipe", callerE164: "+14155550199",
                 claimedIdentity: "", answersJson: String(decoding: try! JSONEncoder().encode(answers), as: UTF8.self),
                 tactics: [], sharedItems: [], severity: answers["q_shared"] == nil ? "" : "medium", status: status,
                 familyAckBy: 0, campaignId: 0, createdAt: ts(Date().addingTimeInterval(-minutesAgo * 60)),
                 resolvedAt: STTimestamp(micros: 0))
    }

    func testGroupsByStatusInFixedOrderNewestFirstAndSkipsEmpty() {
        let reports = ReportsList.make([
            inc(1, answers: ["q_identity": "bank"], status: "in_progress", minutesAgo: 30),
            inc(2, answers: ["q_shared": "nothing"], status: "in_progress", minutesAgo: 20),
            inc(3, answers: [:], status: "open", minutesAgo: 5),
        ])
        let sections = ReportSection.make(reports)
        XCTAssertEqual(sections.map(\.kind), [.needsAnswers, .answered])
        XCTAssertEqual(sections[0].reports.map(\.id), [3, 1], "newest first inside a group")
        XCTAssertEqual(sections[0].title, "Needs your answers")
        XCTAssertFalse(sections.contains { $0.kind == .done })
    }

    func testEmptyInputGivesNoSections() {
        XCTAssertTrue(ReportSection.make([]).isEmpty)
    }
}

final class NetworkAlertLinkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_135_650)

    private func contact(_ id: UInt64, _ name: String) -> Contact {
        Contact(id: id, personId: 1, name: name, phoneE164: "+1512555\(id)00", relationship: "", channel: "imessage",
                isEmergencyContact: false, isAppUser: false, linkedPersonId: 0, consentStatus: "accepted")
    }

    private func incident(_ id: UInt64) -> Incident {
        Incident(id: id, requestKey: "i\(id)", personId: 1, entryPoint: "report_swipe", callerE164: "", claimedIdentity: "",
                 answersJson: "{}", tactics: [], sharedItems: [], severity: "high", status: "in_progress", familyAckBy: 0,
                 campaignId: 0, createdAt: ts(now.addingTimeInterval(-3600)), resolvedAt: STTimestamp(micros: 0))
    }

    func testLinksFamilyToTheThreatsTheyWereAlertedAbout() {
        let tommy = contact(10, "Tommy"), maria = contact(11, "Maria")
        let requests = [
            AlertRequest(id: 1, incidentId: 7, kind: "alert", recipientContactIds: [10, 11], status: "acknowledged",
                         ackedByContactId: 10, createdAt: ts(now.addingTimeInterval(-3000))),
            AlertRequest(id: 2, incidentId: 7, kind: "help", recipientContactIds: [10], status: "pending",
                         createdAt: ts(now.addingTimeInterval(-3500))),
            AlertRequest(id: 3, incidentId: 0, verificationId: 4, kind: "verify", recipientContactIds: [11], status: "pending",
                         createdAt: ts(now.addingTimeInterval(-100))),
            AlertRequest(id: 4, incidentId: 99, kind: "alert", recipientContactIds: [11], status: "pending",
                         createdAt: ts(now.addingTimeInterval(-100))), // incident not shown on the map
        ]
        let d = NetworkDashboard(checks: [], incidents: [incident(7)], alertRequests: requests, contacts: [tommy, maria],
                                 campaigns: [], briefings: [], now: now)
        XCTAssertEqual(d.alertLinks, [
            .init(familyId: 10, threatId: "incident-7", answered: true),
            .init(familyId: 11, threatId: "incident-7", answered: false),
        ])
    }

    func testCallThreatsShowTheCallerNumberAndOpenTheirReport() {
        var withNumber = incident(8)
        withNumber.callerE164 = "+13464819285"
        withNumber.claimedIdentity = "Chase bank"
        let d = NetworkDashboard(checks: [], incidents: [withNumber, incident(9)], alertRequests: [], contacts: [],
                                 campaigns: [], briefings: [], now: now)
        let call = d.threats.first { $0.id == "incident-8" }
        XCTAssertEqual(call?.number, PhoneNumbers.formatted("+13464819285"))
        XCTAssertTrue(call?.title.contains(PhoneNumbers.formatted("+13464819285")) ?? false)
        XCTAssertEqual(call?.claimedIdentity, "Chase bank")
        XCTAssertEqual(call?.incidentId, 8)
        let noNumber = d.threats.first { $0.id == "incident-9" }
        XCTAssertEqual(noNumber?.number, "")
        XCTAssertEqual(noNumber?.incidentId, 9)
    }
}
