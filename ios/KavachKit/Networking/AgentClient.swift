import Foundation

public enum CheckSource: String, Sendable { case appPaste = "app_paste", share, screenshot }

/// `/app/check` response (same shape as scam_check: `{verdict, reason, campaign_id, tips[], evidence_count}`).
/// `highlights` is optional; when absent the UI highlights links and numbers it finds itself.
public struct CheckResult: Codable, Sendable, Equatable {
    public var verdict: Verdict
    public var reason: String
    public var campaignId: UInt64
    public var tips: [String]
    public var evidenceCount: Int
    public var highlights: [String]
    /// True when the agent service could not be reached and this is the spec 13 fallback.
    public var isFallback: Bool
    /// The stored `message_check` row, when the service returns it (used for feedback).
    public var checkId: UInt64?
    public var requestKey: String?

    public init(verdict: Verdict, reason: String, campaignId: UInt64 = 0, tips: [String] = [],
                evidenceCount: Int = 0, highlights: [String] = [], isFallback: Bool = false) {
        self.verdict = verdict; self.reason = reason; self.campaignId = campaignId; self.tips = tips
        self.evidenceCount = evidenceCount; self.highlights = highlights; self.isFallback = isFallback
    }

    enum CodingKeys: String, CodingKey { case verdict, reason, campaignId, tips, evidenceCount, highlights, isFallback, checkId, requestKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = Verdict(wire: (try? c.decode(String.self, forKey: .verdict)) ?? "")
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        campaignId = (try? c.decodeIfPresent(UInt64.self, forKey: .campaignId)) ?? 0
        tips = (try? c.decodeIfPresent([String].self, forKey: .tips)) ?? []
        evidenceCount = (try? c.decodeIfPresent(Int.self, forKey: .evidenceCount)) ?? 0
        highlights = (try? c.decodeIfPresent([String].self, forKey: .highlights)) ?? []
        isFallback = (try? c.decodeIfPresent(Bool.self, forKey: .isFallback)) ?? false
        checkId = try? c.decodeIfPresent(UInt64.self, forKey: .checkId)
        requestKey = try? c.decodeIfPresent(String.self, forKey: .requestKey)
    }

    /// Spec section 13 fallback reply.
    public static let fallback = CheckResult(
        verdict: .suspicious,
        reason: "I couldn't check this right now. Don't reply or tap any links, and ask someone you trust.",
        tips: ["Don't reply or tap any links.", "Ask someone you trust."],
        isFallback: true
    )
}

/// `/app/verify` response (same as verify_relative: `{verification_id, messages[]}`).
public struct VerifyResult: Codable, Sendable, Equatable {
    public var verificationId: UInt64
    public var messages: [String]

    enum CodingKeys: String, CodingKey { case verificationId, messages }
    public init(verificationId: UInt64, messages: [String]) { self.verificationId = verificationId; self.messages = messages }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verificationId = (try? c.decodeIfPresent(UInt64.self, forKey: .verificationId)) ?? 0
        messages = (try? c.decodeIfPresent([String].self, forKey: .messages)) ?? []
    }
}

/// Agent service client for the app endpoints (docs/CONTRACTS.md section 4). Bearer = the app's
/// SpacetimeDB token. The agent service has a 20 s budget; we wait slightly longer, then fall back.
public struct AgentClient: Sendable {
    public let baseURL: URL
    let session: URLSession
    public var timeout: TimeInterval = 22

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Never throws: any failure returns the spec 13 fallback so the UI always has safe advice.
    public func check(text: String, source: CheckSource, senderE164: String?, token: String) async -> CheckResult {
        var body: [String: JSONValue] = ["text": .string(text), "source": .string(source.rawValue)]
        if let s = senderE164, !s.isEmpty { body["sender_e164"] = .string(s) }
        do {
            let data = try await post("app/check", body: body, token: token)
            return try Self.decoder.decode(CheckResult.self, from: data)
        } catch {
            return .fallback
        }
    }

    public func verify(relativeName: String, token: String) async throws -> VerifyResult {
        let data = try await post("app/verify", body: ["relative_name": .string(relativeName)], token: token)
        return try Self.decoder.decode(VerifyResult.self, from: data)
    }

    /// `POST /app/feedback` with the app token. Never throws (training signal only).
    public func feedback(_ fb: VerdictFeedback, checkId: UInt64?, requestKey: String?, token: String) async -> Bool {
        (try? await post("app/feedback", body: fb.body(checkId: checkId, requestKey: requestKey), token: token)) != nil
    }

    public func health() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func post(_ path: String, body: [String: JSONValue], token: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw KavachError.transport(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw KavachError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

/// "Was this right?" answer for a verdict, encoded for `/app/feedback`
/// (`{check_id?, request_key?, correct, label?}`).
public struct VerdictFeedback: Sendable, Equatable {
    public enum Choice: Sendable, Equatable { case right, wasScam, wasSafe }
    public let verdict: Verdict
    public let choice: Choice

    public init(verdict: Verdict, choice: Choice) { self.verdict = verdict; self.choice = choice }

    /// Whether the verdict was right.
    public var correct: Bool {
        switch choice {
        case .right: true
        case .wasScam: verdict == .likelyScam
        case .wasSafe: verdict == .safe
        }
    }

    /// The label the person gave (the true class).
    public var label: Verdict {
        switch choice {
        case .right: verdict
        case .wasScam: .likelyScam
        case .wasSafe: .safe
        }
    }

    public func body(checkId: UInt64?, requestKey: String?) -> [String: JSONValue] {
        var b: [String: JSONValue] = ["correct": .bool(correct), "label": .string(label.rawValue)]
        if let checkId, checkId != 0 { b["check_id"] = .uint(checkId) }
        if let requestKey, !requestKey.isEmpty { b["request_key"] = .string(requestKey) }
        return b
    }
}
