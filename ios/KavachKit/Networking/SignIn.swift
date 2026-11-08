import Foundation
import Observation

// Phone sign-in by one-time code (docs/CONTRACTS.md section 7):
//   POST /v1/identity → request_sign_in(phone, name) → code texted → verify_sign_in(phone, code).
// The SpacetimeDB token is the session; the code proves the number belongs to this phone.
// Demo numbers (+1555555xxxx) accept 000000 when the module runs with DEMO_MODE=true.

/// The caller's pending sign-in (`my_sign_in`). Never contains the code or anything derived from it.
public struct SignInStatus: Codable, Sendable, Hashable {
    public var phoneE164: String
    public var attemptsLeft: UInt8
    public var lastError: String // "" | wrong_code | too_many_attempts
    public var expiresAt: STTimestamp
    public var createdAt: STTimestamp
}

/// Everything that can go wrong signing in, in words a person can act on.
public enum SignInError: LocalizedError, Sendable, Equatable {
    case invalidPhone
    case nameRequired
    case invalidCode
    case wrongCode(attemptsLeft: Int)
    case tooManyAttempts(minutes: Int?)
    case expired
    case noCodeRequested
    case resendTooSoon
    case tooManyRequests
    case other(String)

    /// Maps a reducer error (`KavachError.http`, the module's text) or transport error.
    public static func from(_ error: Error) -> SignInError {
        if let e = error as? SignInError { return e }
        guard case let KavachError.http(_, message)? = error as? KavachError else {
            return .other((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let m = message.lowercased()
        if m.contains("too many attempts") {
            let minutes = m.range(of: #"\d+(?= min)"#, options: .regularExpression).flatMap { Int(m[$0]) }
            return .tooManyAttempts(minutes: minutes)
        }
        if m.contains("e.164") { return .invalidPhone }
        if m.contains("name required") { return .nameRequired }
        if m.contains("6-digit code") { return .invalidCode }
        if m.contains("expired") { return .expired }
        if m.contains("no sign-in code") { return .noCodeRequested }
        if m.contains("wait 30 seconds") { return .resendTooSoon }
        if m.contains("too many codes") { return .tooManyRequests }
        return .other(message.isEmpty ? "The server refused the request." : message)
    }

    /// A wrong code is committed (not an HTTP error), so the result is read back from `my_sign_in`.
    public static func from(status: SignInStatus) -> SignInError? {
        switch status.lastError {
        case "wrong_code": .wrongCode(attemptsLeft: Int(status.attemptsLeft))
        case "too_many_attempts": .tooManyAttempts(minutes: nil)
        default: nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidPhone: "Please check your mobile number, including the area code."
        case .nameRequired: "Please enter your first name."
        case .invalidCode: "Enter the 6 digits from the text message."
        case .wrongCode(let n):
            n == 1 ? "That code isn't right. You have 1 try left." : "That code isn't right. You have \(n) tries left."
        case .tooManyAttempts(let m):
            "Too many wrong codes. For your safety, wait \(m.map { "\($0) minute\($0 == 1 ? "" : "s")" } ?? "10 minutes"), then ask for a new code."
        case .expired: "That code has expired. Ask for a new code."
        case .noCodeRequested: "That code can't be used any more. Ask for a new code."
        case .resendTooSoon: "Please wait a few seconds before asking for another code."
        case .tooManyRequests: "Too many codes were sent to this number. Please try again in an hour."
        case .other(let m): m
        }
    }

    /// The current code can't succeed any more: the screen should offer a new code.
    public var needsNewCode: Bool {
        switch self {
        case .expired, .noCodeRequested, .tooManyAttempts: true
        default: false
        }
    }
}

extension KavachAPI {
    /// Texts a 6-digit code to `phone` (E.164). Replaces this identity's previous pending code.
    public func requestSignIn(phone: String, name: String) async throws {
        do {
            try await db.call("request_sign_in", ["phone": .string(phone), "name": .string(name)], token: token)
        } catch { throw SignInError.from(error) }
    }

    /// Checks the code. On success returns the signed-in person; otherwise throws a `SignInError`
    /// (wrong codes come back from `my_sign_in`, since the module commits the attempt count).
    public func verifySignIn(phone: String, code: String) async throws -> Person {
        do {
            try await db.call("verify_sign_in", ["phone": .string(phone), "code": .string(code)], token: token)
        } catch { throw SignInError.from(error) }
        if let me = try await myPerson(), me.phoneE164 == phone { return me }
        if let status = try await mySignIn(), let e = SignInError.from(status: status) { throw e }
        throw SignInError.noCodeRequested
    }

    /// Releases this phone's number on the server, so another phone (or this one) can sign in again.
    public func signOut() async throws {
        try await db.call("sign_out", [:], token: token)
    }

    public func mySignIn() async throws -> SignInStatus? {
        try await db.query("SELECT * FROM my_sign_in", as: SignInStatus.self, token: token).first
    }

    /// Saves the session for the app and its extensions after a successful sign-in.
    public func remember(_ me: Person, config: AppConfig) {
        let store = SharedStore(appGroup: config.appGroup)
        store.saveToken(token)
        store.set(me.id, .personId)
        store.set(me.displayName, .personName)
    }
}

/// The two-step sign-in screen state: number + name → code. UI-free so it can be tested.
@MainActor
@Observable
public final class SignInFlow {
    public enum Step: Equatable, Sendable { case details, code }

    public static let resendCooldown: TimeInterval = 30
    public static let codeLength = 6

    public private(set) var step: Step = .details
    public var name = ""
    public var phone = ""
    /// Digits only, at most 6 (pasted or autofilled codes are cleaned by `setCode`).
    public private(set) var code = ""
    public private(set) var busy = false
    public var error: SignInError?
    /// The E.164 number the code was sent to.
    public private(set) var phoneE164 = ""
    public private(set) var codeSentAt: Date?

    private let db: SpacetimeClient
    private let agents: AgentClient
    private let now: @Sendable () -> Date
    /// One identity per sign-in attempt; reused for resends and "use a different number".
    private var token: String?

    public init(db: SpacetimeClient, agents: AgentClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.agents = agents
        self.now = now
    }

    public convenience init(config: AppConfig) {
        self.init(db: SpacetimeClient(config: config), agents: AgentClient(baseURL: config.agentURL))
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canSendCode: Bool { !busy && !trimmedName.isEmpty && !normalizePhone(phone).isEmpty }
    public var canVerify: Bool { !busy && code.count == Self.codeLength }

    /// Seconds until "Send a new code" is allowed (0 = now).
    public func secondsUntilResend(at date: Date? = nil) -> Int {
        guard let sent = codeSentAt else { return 0 }
        let left = Self.resendCooldown - (date ?? now()).timeIntervalSince(sent)
        return max(0, Int(left.rounded(.up)))
    }

    public func setCode(_ raw: String) {
        let digits = String(raw.filter { $0.isASCII && $0.isNumber }.prefix(Self.codeLength))
        if digits != code { code = digits }
    }

    private func api() async throws -> KavachAPI {
        if let token { return KavachAPI(db: db, agents: agents, token: token) }
        let t = try await db.newIdentity().token
        token = t
        return KavachAPI(db: db, agents: agents, token: t)
    }

    /// Step 1: "Text me a code".
    public func sendCode() async {
        let e164 = normalizePhone(phone)
        guard !e164.isEmpty else { error = .invalidPhone; return }
        guard !trimmedName.isEmpty else { error = .nameRequired; return }
        busy = true
        defer { busy = false }
        do {
            try await api().requestSignIn(phone: e164, name: trimmedName)
            phoneE164 = e164
            codeSentAt = now()
            code = ""
            error = nil
            step = .code
        } catch {
            self.error = SignInError.from(error)
        }
    }

    /// Step 2: "Send a new code" (after the cooldown).
    public func resend() async {
        guard secondsUntilResend() == 0, !phoneE164.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await api().requestSignIn(phone: phoneE164, name: trimmedName)
            codeSentAt = now()
            code = ""
            error = nil
        } catch {
            self.error = SignInError.from(error)
        }
    }

    /// Step 2: checks the code. Returns the signed-in API and person on success.
    public func verify() async -> (KavachAPI, Person)? {
        guard code.count == Self.codeLength else { error = .invalidCode; return nil }
        busy = true
        defer { busy = false }
        do {
            let api = try await api()
            let me = try await api.verifySignIn(phone: phoneE164, code: code)
            error = nil
            return (api, me)
        } catch {
            self.error = SignInError.from(error)
            code = ""
            return nil
        }
    }

    /// Back to step 1 with the same name (the pending code is replaced by the next request).
    public func useDifferentNumber() {
        step = .details
        code = ""
        error = nil
        codeSentAt = nil
    }
}
