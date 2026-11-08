import XCTest
@testable import KavachKit

final class InterviewEncodingTests: XCTestCase {
    func testQuestionIdsMatchContract() {
        XCTAssertEqual(InterviewScript.questions.map(\.id), ["q_identity", "q_ask", "q_shared", "q_secrecy", "q_help"])
    }

    func testAnswerValuesMatchContract() {
        func values(_ id: String) -> [String] {
            switch InterviewScript.questions.first(where: { $0.id == id })!.kind {
            case .single(let o), .multi(let o, _): o.map(\.value)
            case .text: []
            }
        }
        XCTAssertEqual(Set(values("q_ask")), ["yes", "no", "agreed"])
        XCTAssertEqual(Set(values("q_secrecy")), ["yes", "no"])
        XCTAssertEqual(Set(values("q_help")), ["yes", "no"])
        XCTAssertEqual(values("q_shared"), InterviewScript.sharedItems + ["nothing"])
        XCTAssertEqual(InterviewScript.sharedItems,
                       ["code", "pin", "password", "card", "gift_card", "money", "remote_app", "personal_details", "link"])
    }

    func testSharedMultiSelectEncodesCommaListInContractOrder() {
        XCTAssertEqual(InterviewScript.sharedAnswer(["link", "personal_details"]), "personal_details,link")
        XCTAssertEqual(InterviewScript.sharedAnswer(["gift_card"]), "gift_card")
        XCTAssertEqual(InterviewScript.sharedAnswer(["nothing"]), "nothing")
        XCTAssertNil(InterviewScript.sharedAnswer([]))
    }

    func testNothingIsExclusive() {
        var s: Set<String> = []
        s = InterviewScript.toggle("card", in: s)
        s = InterviewScript.toggle("link", in: s)
        XCTAssertEqual(s, ["card", "link"])
        s = InterviewScript.toggle("nothing", in: s)
        XCTAssertEqual(s, ["nothing"])
        s = InterviewScript.toggle("code", in: s)
        XCTAssertEqual(s, ["code"])
        s = InterviewScript.toggle("code", in: s)
        XCTAssertEqual(s, [])
    }

    func testIdentityAnswerTrimsAndRejectsEmpty() {
        XCTAssertEqual(InterviewScript.identityAnswer("  My bank \n"), "My bank")
        XCTAssertNil(InterviewScript.identityAnswer("   "))
        XCTAssertEqual(InterviewScript.identityAnswer(String(repeating: "x", count: 200))?.count, 80)
    }

    func testSpokenQuestionIncludesProgressAndOptions() {
        let s = InterviewScript.spoken(InterviewScript.questions[1], index: 1)
        XCTAssertTrue(s.hasPrefix("Question 2 of 5."))
        XCTAssertTrue(s.contains("Yes, they asked"))
    }
}

final class AccessibilityModeTests: XCTestCase {
    func testOffByDefault() {
        let p = DisplayPreferences()
        XCTAssertFalse(p.accessibilityMode)
        XCTAssertFalse(p.autoSpeak)
        XCTAssertFalse(p.homeShowsOnlyActions)
        XCTAssertFalse(p.hapticsOnEveryTap)
    }

    func testAccessibilityModeTurnsOnEveryAdaptation() {
        let p = DisplayPreferences(accessibilityMode: true)
        XCTAssertTrue(p.autoSpeak)
        XCTAssertTrue(p.useLargerText)
        XCTAssertTrue(p.highContrast)
        XCTAssertTrue(p.hapticsOnEveryTap)
        XCTAssertTrue(p.homeShowsOnlyActions)
    }

    func testIndividualTogglesWithoutAccessibilityMode() {
        let p = DisplayPreferences(spokenVerdicts: true, largerText: true)
        XCTAssertTrue(p.autoSpeak)
        XCTAssertTrue(p.useLargerText)
        XCTAssertFalse(p.homeShowsOnlyActions, "only Accessibility Mode changes Home")
        XCTAssertFalse(p.highContrast)
    }

    func testPersistsInSharedStore() {
        let store = SharedStore(appGroup: "test.kavach.\(UUID().uuidString)")
        DisplayPreferences(accessibilityMode: true, spokenVerdicts: false, largerText: true).save(to: store)
        XCTAssertEqual(DisplayPreferences.load(from: store),
                       DisplayPreferences(accessibilityMode: true, spokenVerdicts: false, largerText: true))
    }

    func testCallerLabelsCacheRoundTrip() throws {
        let store = SharedStore(appGroup: "test.kavach.\(UUID().uuidString)")
        let labels = [CallerLabel(value: "+15555550199", reporterCount: 14)]
        try store.saveCallerLabels(labels)
        XCTAssertEqual(store.loadCallerLabels(), labels)
    }

    func testConfigReadsInfoPlistAndIgnoresUnexpandedVars() {
        let c = AppConfig.fromInfoPlist([
            "KavachAppDisplayName": "Kavach", "KavachSpacetimeURL": "http://192.168.1.20:3000",
            "KavachSpacetimeDB": "kavach", "KavachAgentURL": "$(AGENT_SERVICE_URL)",
        ])
        XCTAssertEqual(c.displayName, "Kavach")
        XCTAssertEqual(c.spacetimeURL.absoluteString, "http://192.168.1.20:3000")
        XCTAssertEqual(c.agentURL.absoluteString, "http://127.0.0.1:8088")
    }
}
