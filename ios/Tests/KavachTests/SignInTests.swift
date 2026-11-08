import XCTest
@testable import KavachKit

/// Error mapping for the sign-in screen (no server needed).
final class SignInErrorMappingTests: XCTestCase {
    private func map(_ message: String) -> SignInError {
        SignInError.from(KavachError.http(status: 530, message: message))
    }

    func testModuleErrorsMapToActionableErrors() {
        XCTAssertEqual(map("invalid phone: must be E.164"), .invalidPhone)
        XCTAssertEqual(map("name required"), .nameRequired)
        XCTAssertEqual(map("enter the 6-digit code"), .invalidCode)
        XCTAssertEqual(map("code expired: ask for a new code"), .expired)
        XCTAssertEqual(map("no sign-in code was requested for this number"), .noCodeRequested)
        XCTAssertEqual(map("too many attempts: try again in 7 min"), .tooManyAttempts(minutes: 7))
        XCTAssertEqual(map("please wait 30 seconds before asking for another code"), .resendTooSoon)
        XCTAssertEqual(map("too many codes requested: try again in an hour"), .tooManyRequests)
        XCTAssertEqual(map("something else"), .other("something else"))
        XCTAssertEqual(SignInError.from(KavachError.transport("offline")), .other("Can't reach the server. offline"))
    }

    func testWrongCodeComesFromMySignIn() {
        let ts = STTimestamp(micros: 1)
        let wrong = SignInStatus(phoneE164: "+15555550101", attemptsLeft: 3, lastError: "wrong_code", expiresAt: ts, createdAt: ts)
        XCTAssertEqual(SignInError.from(status: wrong), .wrongCode(attemptsLeft: 3))
        var locked = wrong
        locked.lastError = "too_many_attempts"; locked.attemptsLeft = 0
        XCTAssertEqual(SignInError.from(status: locked), .tooManyAttempts(minutes: nil))
        var pending = wrong
        pending.lastError = ""
        XCTAssertNil(SignInError.from(status: pending))
    }

    func testMessagesAndNewCodeHint() {
        XCTAssertEqual(SignInError.wrongCode(attemptsLeft: 1).errorDescription, "That code isn't right. You have 1 try left.")
        XCTAssertEqual(SignInError.wrongCode(attemptsLeft: 4).errorDescription, "That code isn't right. You have 4 tries left.")
        XCTAssertTrue(SignInError.tooManyAttempts(minutes: 1).errorDescription!.contains("wait 1 minute,"))
        XCTAssertTrue(SignInError.expired.needsNewCode)
        XCTAssertTrue(SignInError.noCodeRequested.needsNewCode)
        XCTAssertTrue(SignInError.tooManyAttempts(minutes: nil).needsNewCode)
        XCTAssertFalse(SignInError.wrongCode(attemptsLeft: 2).needsNewCode)
    }

    func testStatusDecodesFromSQLRow() throws {
        let json = #"[{"schema":{"elements":[{"name":{"some":"phone_e164"}},{"name":{"some":"attempts_left"}},{"name":{"some":"last_error"}},{"name":{"some":"expires_at"}},{"name":{"some":"created_at"}}]},"rows":[["+15555550101",4,"wrong_code",[1700000000000000],[1699999999000000]]]}]"#
        let rows = try SQLDecoder.decode(SignInStatus.self, from: Data(json.utf8))
        XCTAssertEqual(rows.first?.attemptsLeft, 4)
        XCTAssertEqual(rows.first?.lastError, "wrong_code")
        XCTAssertEqual(rows.first?.expiresAt.micros, 1_700_000_000_000_000)
    }
}

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// The two-step flow against the local `kavach-ios` database (DEMO_MODE=true). Skipped when unreachable.
@MainActor
final class SignInFlowLiveTests: XCTestCase {
    private func client() async throws -> SpacetimeClient {
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["KAVACH_TEST_SPACETIME_URL"] ?? "http://127.0.0.1:3000")!
        let db = SpacetimeClient(baseURL: url, database: env["KAVACH_TEST_DB"] ?? "kavach-ios")
        do { _ = try await db.newIdentity() } catch { throw XCTSkip("SpacetimeDB not reachable at \(url)") }
        return db
    }
    private let agents = AgentClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    private func demoPhone() -> String { "+1555555" + String(format: "%04d", Int.random(in: 1_000...9_999)) }

    func testCodeEntryFiltersToSixDigits() {
        let flow = SignInFlow(db: SpacetimeClient(baseURL: URL(string: "http://127.0.0.1:9")!, database: "x"), agents: agents)
        flow.setCode("12 34-5678")
        XCTAssertEqual(flow.code, "123456")
        XCTAssertTrue(flow.canVerify)
        flow.phone = "555"
        flow.name = "Joe"
        XCTAssertFalse(flow.canSendCode, "needs a full number")
        flow.phone = "(555) 555-0101"
        XCTAssertTrue(flow.canSendCode)
    }

    func testTwoStepSignInWithWrongCodeThenDemoCode() async throws {
        let db = try await client()
        let clock = TestClock()
        let flow = SignInFlow(db: db, agents: agents, now: { clock.date })
        flow.name = "Flow Test"
        flow.phone = demoPhone()
        await flow.sendCode()
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.step, .code)
        XCTAssertEqual(flow.secondsUntilResend(), 30, "resend cooldown starts")
        clock.date.addTimeInterval(12)
        XCTAssertEqual(flow.secondsUntilResend(), 18)

        flow.setCode("123456")
        let wrong = await flow.verify()
        XCTAssertNil(wrong)
        XCTAssertEqual(flow.error, .wrongCode(attemptsLeft: 4))
        XCTAssertEqual(flow.step, .code)
        XCTAssertEqual(flow.code, "", "a wrong code is cleared for the next try")

        flow.setCode("000000")
        let ok = await flow.verify()
        let (api, me) = try XCTUnwrap(ok)
        XCTAssertEqual(me.phoneE164, flow.phoneE164)
        XCTAssertEqual(me.displayName, "Flow Test")
        XCTAssertNil(flow.error)
        let stillPending = try await api.mySignIn()
        XCTAssertNil(stillPending, "the challenge is gone after sign-in")
    }

    func testUseDifferentNumberGoesBackToStepOne() async throws {
        let db = try await client()
        let flow = SignInFlow(db: db, agents: agents)
        flow.name = "Switch"
        flow.phone = demoPhone()
        await flow.sendCode()
        XCTAssertEqual(flow.step, .code)
        flow.useDifferentNumber()
        XCTAssertEqual(flow.step, .details)
        XCTAssertEqual(flow.name, "Switch")
        XCTAssertEqual(flow.secondsUntilResend(), 0)
    }

    /// The reported bug: sign out, then sign in again with a fresh identity → no "already registered".
    func testSignOutReleasesTheNumberAndANewDeviceTakesOver() async throws {
        let db = try await client()
        let phone = demoPhone()
        let first = KavachAPI(db: db, agents: agents, token: try await db.newIdentity().token)
        try await first.requestSignIn(phone: phone, name: "Device A")
        _ = try await first.verifySignIn(phone: phone, code: "000000")

        // A second device verifying the number takes it over; the first stops seeing it.
        let second = KavachAPI(db: db, agents: agents, token: try await db.newIdentity().token)
        try await second.requestSignIn(phone: phone, name: "Device B")
        let me = try await second.verifySignIn(phone: phone, code: "000000")
        XCTAssertEqual(me.displayName, "Device B")
        let firstAfterTakeover = try await first.myPerson()
        XCTAssertNil(firstAfterTakeover)

        // Sign out releases it; a third identity can sign in again.
        try await second.signOut()
        let secondAfterSignOut = try await second.myPerson()
        XCTAssertNil(secondAfterSignOut)
        let third = KavachAPI(db: db, agents: agents, token: try await db.newIdentity().token)
        try await third.requestSignIn(phone: phone, name: "Device C")
        let again = try await third.verifySignIn(phone: phone, code: "000000")
        XCTAssertEqual(again.id, me.id, "same person, new device")
    }

    func testResendTooSoonAndLockoutForARealNumber() async throws {
        let db = try await client()
        // Fictional 415-555-01xx number: a real code is queued (nobody delivers it), 000000 is not accepted.
        let phone = "+14155550" + String(format: "%03d", Int.random(in: 100...199))
        let api = KavachAPI(db: db, agents: agents, token: try await db.newIdentity().token)
        do { try await api.requestSignIn(phone: phone, name: "Locked") } catch SignInError.tooManyRequests {
            throw XCTSkip("this fictional number hit its hourly limit; rerun")
        }
        do { try await api.requestSignIn(phone: phone, name: "Locked"); XCTFail("expected cooldown") }
        catch { XCTAssertEqual(error as? SignInError, .resendTooSoon) }

        for left in (1...4).reversed() {
            do { _ = try await api.verifySignIn(phone: phone, code: "000000"); XCTFail("demo code must not work") }
            catch { XCTAssertEqual(error as? SignInError, .wrongCode(attemptsLeft: left)) }
        }
        do { _ = try await api.verifySignIn(phone: phone, code: "000000"); XCTFail("expected lockout") }
        catch { XCTAssertEqual(error as? SignInError, .tooManyAttempts(minutes: nil)) }
        do { _ = try await api.verifySignIn(phone: phone, code: "000000"); XCTFail("still locked") }
        catch {
            guard case .tooManyAttempts = error as? SignInError else { return XCTFail("\(error)") }
            XCTAssertTrue((error as? SignInError)?.needsNewCode ?? false)
        }
    }
}
