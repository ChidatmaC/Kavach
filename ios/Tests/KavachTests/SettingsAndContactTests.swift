import Contacts
import XCTest
@testable import KavachKit

private func person(paused: Bool = false, accessibility: Bool = false) -> Person {
    Person(id: 7, ownerHex: "ab", phoneE164: "+15555550101", displayName: "Joe", accessibilityMode: accessibility,
           sharingPaused: paused, criticalOverridesPause: false, apnsToken: "",
           familyCodeWord: "", tzOffsetMinutes: 0, recoveryWatchUntil: STTimestamp(micros: 0),
           campaignWatchUntil: STTimestamp(micros: 0), createdAt: STTimestamp(micros: 1))
}

private struct WriteFailed: LocalizedError { var errorDescription: String? { "Server said no" } }

/// Waits on the main actor until `condition` holds (the write closure below suspends on a continuation).
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { await Task.yield() }
}

@MainActor
final class PersonSettingsStateTests: XCTestCase {
    func testToggleShowsNewValueBeforeTheWriteFinishes() async {
        let state = PersonSettingsState(person: person())
        var resume: CheckedContinuation<Void, Never>?
        let task = Task { await state.set(.sharingPaused, to: true) { _ in await withCheckedContinuation { resume = $0 } } }
        await until { resume != nil }
        XCTAssertEqual(state.person?.sharingPaused, true, "optimistic: the toggle flips at once")
        XCTAssertTrue(state.isPending(.sharingPaused))
        resume?.resume()
        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertEqual(state.person?.sharingPaused, true)
        XCTAssertFalse(state.isPending(.sharingPaused))
        XCTAssertNil(state.lastError)
    }

    func testFailedWriteRevertsAndReportsError() async {
        let state = PersonSettingsState(person: person())
        let ok = await state.set(.sharingPaused, to: true) { p in
            XCTAssertTrue(p.sharingPaused, "the write receives the changed row")
            throw WriteFailed()
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(state.person?.sharingPaused, false, "reverted")
        XCTAssertEqual(state.lastError, "Server said no")
    }

    func testWriteCarriesOtherInFlightChanges() async {
        let state = PersonSettingsState(person: person())
        var resume: CheckedContinuation<Void, Never>?
        let first = Task { await state.set(.criticalOverridesPause, to: true) { _ in await withCheckedContinuation { resume = $0 } } }
        await until { resume != nil }
        var written: Person?
        await state.set(.accessibilityMode, to: true) { written = $0 }
        XCTAssertEqual(written?.criticalOverridesPause, true, "update_settings must not undo a pending toggle")
        XCTAssertEqual(written?.accessibilityMode, true)
        resume?.resume()
        _ = await first.value
        XCTAssertEqual(state.person?.criticalOverridesPause, true)
        XCTAssertEqual(state.person?.accessibilityMode, true)
    }

    func testPolledSharingPausedChangeIsReflected() {
        // The person texts "pause" to the agent; the next my_person poll carries it.
        let state = PersonSettingsState(person: person(paused: false))
        XCTAssertEqual(SettingToggle.sharingPaused.appearance(isOn: state.person!.sharingPaused).systemImage, "bell.fill")
        state.receive(person(paused: true), fetch: state.beginFetch())
        XCTAssertEqual(state.person?.sharingPaused, true)
        XCTAssertEqual(SettingToggle.sharingPaused.appearance(isOn: state.person!.sharingPaused).status, "Family alerts paused")
        state.receive(person(paused: false), fetch: state.beginFetch()) // "resume"
        XCTAssertEqual(state.person?.sharingPaused, false)
    }

    func testPollDuringPendingWriteDoesNotFlipToggleBack() async {
        let state = PersonSettingsState(person: person())
        let staleFetch = state.beginFetch() // poll started before the tap
        var resume: CheckedContinuation<Void, Never>?
        let task = Task { await state.set(.sharingPaused, to: true) { _ in await withCheckedContinuation { resume = $0 } } }
        await until { resume != nil }
        state.receive(person(paused: false), fetch: staleFetch)
        XCTAssertEqual(state.person?.sharingPaused, true, "pending value wins over a stale poll")
        resume?.resume()
        _ = await task.value
        state.receive(person(paused: false), fetch: staleFetch) // arrives after the write settled
        XCTAssertEqual(state.person?.sharingPaused, true, "a poll that started before the write is ignored")
        state.receive(person(paused: false), fetch: state.beginFetch()) // fresh poll: someone resumed by text
        XCTAssertEqual(state.person?.sharingPaused, false)
    }

    func testEveryToggleHasDistinctIconAndStatusPerState() {
        for s in SettingToggle.allCases {
            let on = s.appearance(isOn: true), off = s.appearance(isOn: false)
            XCTAssertNotEqual(on.systemImage, off.systemImage, "\(s)")
            XCTAssertNotEqual(on.status, off.status, "\(s)")
        }
        XCTAssertEqual(SettingToggle.sharingPaused.appearance(isOn: true).tone, .attention)
        XCTAssertEqual(SettingToggle.sharingPaused.appearance(isOn: false).tone, .on)
        XCTAssertEqual(SettingToggle.sharingPaused.appearance(isOn: false).status, "Family alerts on")
        XCTAssertEqual(SettingToggle.sharingPaused.personKeyPath, \Person.sharingPaused)
        XCTAssertNil(SettingToggle.spokenVerdicts.personKeyPath)
    }
}

final class AgentContactTests: XCTestCase {
    func testContactHasNameNumberAndNote() {
        let c = AgentContact.make(displayName: "Kavach", number: "+14156106180", imageData: Data([1, 2, 3]))
        XCTAssertEqual(c.givenName, "Kavach")
        XCTAssertEqual(c.phoneNumbers.count, 1)
        XCTAssertEqual(c.phoneNumbers.first?.label, CNLabelPhoneNumberiPhone)
        XCTAssertEqual(c.phoneNumbers.first?.value.stringValue, "+14156106180")
        XCTAssertTrue(c.note.contains("Text me any message you're unsure about"), c.note)
        XCTAssertEqual(c.imageData, Data([1, 2, 3]))
    }

    func testContactFollowsConfig() {
        let info: [String: Any] = ["KavachAppDisplayName": "Kavach", "KavachAgentLineNumber": "+14156106180"]
        let config = AppConfig.fromInfoPlist(info)
        XCTAssertEqual(config.agentLineNumber, "+14156106180")
        let c = AgentContact.make(config: config)
        XCTAssertEqual(c.givenName, "Kavach")
        XCTAssertEqual(c.phoneNumbers.first?.value.stringValue, "+14156106180")
        XCTAssertEqual(AppConfig.fromInfoPlist(["KavachAgentLineNumber": "$(AGENT_LINE_NUMBER)"]).agentLineNumber, "")
    }

    func testMessagesURLAndFormatting() {
        XCTAssertEqual(AgentContact.messagesURL(number: "+14156106180")?.absoluteString, "sms:+14156106180")
        XCTAssertNil(AgentContact.messagesURL(number: ""))
        XCTAssertEqual(AgentContact.formatted("+14156106180"), "+1 (415) 610-6180")
    }

    func testPromptIsRememberedInAppGroup() {
        let store = SharedStore(appGroup: "group.test.kavach.\(UUID().uuidString)")
        XCTAssertNil(AgentContactPrompt.load(from: store))
        AgentContactPrompt.save(.dismissed, to: store)
        XCTAssertEqual(AgentContactPrompt.load(from: store), .dismissed)
        AgentContactPrompt.save(.saved, to: store)
        XCTAssertEqual(AgentContactPrompt.load(from: store), .saved)
    }
}
