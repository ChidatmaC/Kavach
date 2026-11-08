import XCTest
@testable import KavachKit

/// JSON decoding of SpacetimeDB `/sql` responses (shapes captured from the live module).
final class DecodingTests: XCTestCase {
    private func ts(_ name: String) -> String {
        #"{"name":{"some":"\#(name)"},"algebraic_type":{"Product":{"elements":[{"name":{"some":"__timestamp_micros_since_unix_epoch__"},"algebraic_type":{"I64":[]}}]}}}"#
    }
    private func col(_ name: String, _ type: String) -> String {
        #"{"name":{"some":"\#(name)"},"algebraic_type":{"\#(type)":[]}}"#
    }

    func testPersonRowWithTimestampsAndSentinels() throws {
        let elements = [
            col("id", "U64"), col("owner_hex", "String"), col("phone_e164", "String"), col("display_name", "String"),
            col("accessibility_mode", "Bool"), col("sharing_paused", "Bool"), col("critical_overrides_pause", "Bool"),
            col("apns_token", "String"), col("family_code_word", "String"),
            col("tz_offset_minutes", "I32"), ts("recovery_watch_until"), ts("campaign_watch_until"),
            col("watch_campaign_id", "U64"), col("watch_caller_e164", "String"), ts("created_at"),
        ].joined(separator: ",")
        let json = #"[{"schema":{"elements":[\#(elements)]},"rows":[[3,"c200bb","+15555559911","Test",false,true,false,"","blue pancake",-360,[0],[1794135650335796],0,"",[1794135650335796]]],"total_duration_micros":1286,"stats":{"rows_inserted":0}}]"#
        let people = try SQLDecoder.decode(Person.self, from: Data(json.utf8))
        XCTAssertEqual(people.count, 1)
        let p = people[0]
        XCTAssertEqual(p.id, 3)
        XCTAssertEqual(p.phoneE164, "+15555559911")
        XCTAssertEqual(p.displayName, "Test")
        XCTAssertTrue(p.sharingPaused)
        XCTAssertEqual(p.familyCodeWord, "blue pancake")
        XCTAssertEqual(p.tzOffsetMinutes, -360)
        XCTAssertFalse(p.recoveryWatchUntil.isSet, "[0] is the unset sentinel")
        XCTAssertNil(p.recoveryWatchUntil.date)
        XCTAssertTrue(p.campaignWatchUntil.isSet)
        XCTAssertEqual(p.createdAt.micros, 1_794_135_650_335_796)
        XCTAssertEqual(p.createdAt.date!.timeIntervalSince1970, 1_794_135_650.335796, accuracy: 0.001)
        XCTAssertEqual(p.apnsToken, "", "\"\" is the unset string sentinel")
    }

    func testIncidentRowWithArraysAndEmptySeverity() throws {
        let names = ["id", "request_key", "person_id", "entry_point", "caller_e164", "claimed_identity", "answers_json",
                     "tactics", "shared_items", "severity", "status", "family_ack_by", "campaign_id", "summary_redacted",
                     "created_at", "resolved_at"]
        let elements = names.map { #"{"name":{"some":"\#($0)"}}"# }.joined(separator: ",")
        let json = #"[{"schema":{"elements":[\#(elements)]},"rows":[[7,"k-1",3,"report_swipe","+15555550199","","{\"q_ask\":\"yes\",\"q_shared\":\"personal_details\"}",["urgency"],["personal_details"],"high","in_progress",0,1,"",[1794135650335796],[0]],[8,"k-2",3,"app","","","{}",[],[],"","open",0,0,"",[1794135650335797],[0]]]}]"#
        let incs = try SQLDecoder.decode(Incident.self, from: Data(json.utf8))
        XCTAssertEqual(incs.count, 2)
        XCTAssertEqual(incs[0].severityLevel, .high)
        XCTAssertEqual(incs[0].sharedItems, ["personal_details"])
        XCTAssertEqual(incs[0].answers["q_ask"], "yes")
        XCTAssertFalse(incs[0].resolvedAt.isSet)
        XCTAssertEqual(incs[1].severityLevel, .unrated, "\"\" severity = not rated yet")
        XCTAssertEqual(incs[1].familyAckBy, 0)
        XCTAssertTrue(incs[1].tactics.isEmpty)
    }

    func testCallerLabelsAndLabelText() throws {
        let json = #"[{"schema":{"elements":[{"name":{"some":"value"},"algebraic_type":{"String":[]}},{"name":{"some":"reporter_count"},"algebraic_type":{"U32":[]}}]},"rows":[["+15555550199",14],["+15555550188",6]]}]"#
        let labels = try SQLDecoder.decode(CallerLabel.self, from: Data(json.utf8))
        XCTAssertEqual(labels.map(\.value), ["+15555550199", "+15555550188"])
        XCTAssertEqual(labels[0].labelText, "Likely scam: 14 reports")
        XCTAssertEqual(labels[0].callKitNumber, 15555550199)
        XCTAssertEqual(CallerLabel(value: "+1", reporterCount: 1).labelText, "Likely scam: 1 report")
    }

    func testEmptyResultAndExtraColumnsAreTolerated() throws {
        let empty = #"[{"schema":{"elements":[{"name":{"some":"value"}}]},"rows":[]}]"#
        XCTAssertEqual(try SQLDecoder.decode(CallerLabel.self, from: Data(empty.utf8)).count, 0)
        let extra = #"[{"schema":{"elements":[{"name":{"some":"value"}},{"name":{"some":"reporter_count"}},{"name":{"some":"new_col"}}]},"rows":[["+1555",3,"x"]]}]"#
        XCTAssertEqual(try SQLDecoder.decode(CallerLabel.self, from: Data(extra.utf8)).first?.reporterCount, 3)
    }

    func testTimestampAlternateEncodingsAndRoundTrip() throws {
        let a = try JSONDecoder().decode(STTimestamp.self, from: Data("[42]".utf8))
        let b = try JSONDecoder().decode(STTimestamp.self, from: Data(#"{"__timestamp_micros_since_unix_epoch__":42}"#.utf8))
        let c = try JSONDecoder().decode(STTimestamp.self, from: Data("42".utf8))
        XCTAssertEqual(a, b); XCTAssertEqual(b, c)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(a), as: UTF8.self), "[42]")
    }

    func testReducerArgsEncodeAsPlainJSONNumbers() throws {
        let args: [String: JSONValue] = ["incident_id": .id(12), "done": true, "tags": .strings(["a"]), "tz": .int(-360)]
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(args)) as! [String: Any]
        XCTAssertEqual(obj["incident_id"] as? Int, 12)
        XCTAssertEqual(obj["done"] as? Bool, true)
        XCTAssertEqual(obj["tags"] as? [String], ["a"])
        XCTAssertEqual(obj["tz"] as? Int, -360)
    }

    func testCheckResultDecodingAndFallback() throws {
        let json = #"{"verdict":"likely_scam","reason":"Fake toll text.","campaign_id":2,"tips":["Don't tap the link"],"evidence_count":5}"#
        let r = try AgentClient.decoder.decode(CheckResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.verdict, .likelyScam)
        XCTAssertEqual(r.verdict.word, "Likely scam")
        XCTAssertEqual(r.campaignId, 2)
        XCTAssertEqual(r.evidenceCount, 5)
        XCTAssertFalse(r.isFallback)
        let odd = try AgentClient.decoder.decode(CheckResult.self, from: Data(#"{"verdict":"weird"}"#.utf8))
        XCTAssertEqual(odd.verdict, .suspicious, "unknown verdicts degrade to Suspicious")
        XCTAssertEqual(Verdict.safe.word, "Looks safe")
        XCTAssertEqual(Verdict.suspicious.word, "Suspicious")
    }

    func testAgentUnreachableReturnsSpecFallback() async {
        let client = AgentClient(baseURL: URL(string: "http://127.0.0.1:9")!) // discard port: nothing listens
        let r = await client.check(text: "Pay your toll", source: .appPaste, senderE164: nil, token: "t")
        XCTAssertTrue(r.isFallback)
        XCTAssertEqual(r.reason, "I couldn't check this right now. Don't reply or tap any links, and ask someone you trust.")
    }

    func testPhoneNormalization() {
        XCTAssertEqual(normalizePhone("(555) 555-0101"), "+15555550101")
        XCTAssertEqual(normalizePhone("+1 555 555 0101"), "+15555550101")
        XCTAssertEqual(normalizePhone("1-555-555-0101"), "+15555550101")
        XCTAssertEqual(normalizePhone(""), "")
    }

    func testRecoveryLibraryBundledFromSharedYAML() {
        let lib = RecoveryLibrary.shared
        XCTAssertEqual(lib.steps.count, 15)
        XCTAssertEqual(lib.steps["credit_freeze"]?.priority, "today")
        XCTAssertTrue(lib.text(for: "credit_freeze").hasPrefix("Freeze your credit at Equifax"))
        XCTAssertTrue(lib.text(for: "report_ftc").contains("ReportFraud.ftc.gov"))
        XCTAssertFalse(lib.text(for: "unknown_key").isEmpty)
    }
}
