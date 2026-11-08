import CryptoKit
import Foundation

/// A call reported from Recents (Unwanted Communication extension, docs/CONTRACTS.md section 7).
///
/// The extension can't use the network. It returns an `ILClassificationResponse` whose `userInfo`
/// is `userInfo` below; iOS POSTs it to `<AGENT_SERVICE_URL>/ios/call-report`. The same report is
/// saved in the App Group and the app replays it on the next launch through the normal reducers,
/// idempotent by `requestKey` (derived from the caller and the report time, so the service can
/// compute the same key).
public struct CallReport: Codable, Sendable, Equatable, Identifiable {
    public var token: String
    public var callerE164: String
    /// `q_*` → wire answer (docs/CONTRACTS.md section 2).
    public var answers: [String: String]
    /// Microseconds since the Unix epoch.
    public var reportedAtMicros: Int64
    public var requestKey: String

    public var id: String { requestKey }

    public init(token: String, callerE164: String, answers: [String: String], reportedAt: Date) {
        self.token = token
        self.callerE164 = callerE164
        self.answers = answers
        self.reportedAtMicros = STTimestamp(date: reportedAt).micros
        self.requestKey = Self.requestKey(callerE164: callerE164, reportedAtMicros: reportedAtMicros)
    }

    /// `ios-report-` + the first 40 hex chars of sha256("<caller>|<micros>") (≤ 64 chars).
    public static func requestKey(callerE164: String, reportedAtMicros: Int64) -> String {
        let digest = SHA256.hash(data: Data("\(callerE164)|\(reportedAtMicros)".utf8))
        return "ios-report-" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
    }

    /// `ILClassificationResponse.userInfo` (JSON-serializable, snake_case keys):
    /// `{token, caller_e164, answers, reported_at, request_key}`.
    public var userInfo: [String: Any] {
        [
            "token": token,
            "caller_e164": callerE164,
            "answers": answers,
            "reported_at": reportedAtMicros,
            "request_key": requestKey,
        ]
    }

    /// Answers in contract order, so replay saves them the way the interview did.
    public var orderedAnswers: [(String, String)] {
        let order = InterviewScript.allQuestionIds + ["q_engaged", "q_summary"]
        return answers.sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
            .map { ($0.key, $0.value) }
    }
}

/// App Group queue of reports the app hasn't confirmed on the server yet.
public struct CallReportStore: Sendable {
    public let fileURL: URL

    public init(store: SharedStore) {
        fileURL = store.containerURL.appendingPathComponent("pending_call_reports.json")
    }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func pending() -> [CallReport] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CallReport].self, from: data)) ?? []
    }

    /// Adds or replaces (same request key) a report.
    public func save(_ report: CallReport) {
        var all = pending().filter { $0.requestKey != report.requestKey }
        all.append(report)
        write(all)
    }

    public func remove(requestKey: String) {
        write(pending().filter { $0.requestKey != requestKey })
    }

    private func write(_ reports: [CallReport]) {
        if let data = try? JSONEncoder().encode(reports) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// What replay needs from the backend (KavachAPI conforms; tests use a fake).
public protocol CallReportBackend: Sendable {
    func openIncident(requestKey: String, personId: UInt64, entryPoint: String, callerE164: String) async throws -> Incident
    func saveAnswer(incidentId: UInt64, questionId: String, answer: String) async throws
    func reportValue(personId: UInt64, kind: String, value: String) async throws
}

extension KavachAPI: CallReportBackend {}

public enum CallReportReplayer {
    public struct Outcome: Sendable, Equatable {
        public var replayed: [String] = []
        public var failed: [String] = []
    }

    /// Replays every pending report through `open_incident(report_swipe)`, `save_answer` (only answers
    /// the incident doesn't have yet, so a report the service already delivered isn't re-saved) and
    /// `report_number`. Successful reports leave the queue; failures stay for the next launch.
    /// Reports made under a different sign-in are dropped.
    public static func replay(store: CallReportStore, backend: CallReportBackend, token: String,
                              personId: UInt64) async -> Outcome {
        var out = Outcome()
        guard personId != 0 else { return out }
        for report in store.pending() {
            guard report.token == token else { store.remove(requestKey: report.requestKey); continue }
            do {
                let inc = try await backend.openIncident(requestKey: report.requestKey, personId: personId,
                                                         entryPoint: "report_swipe", callerE164: report.callerE164)
                if !inc.isResolved {
                    let have = inc.answers
                    for (q, a) in report.orderedAnswers where have[q] == nil {
                        try await backend.saveAnswer(incidentId: inc.id, questionId: q, answer: a)
                    }
                }
                if !report.callerE164.isEmpty {
                    try await backend.reportValue(personId: personId, kind: "number", value: report.callerE164)
                }
                store.remove(requestKey: report.requestKey)
                out.replayed.append(report.requestKey)
            } catch {
                out.failed.append(report.requestKey)
            }
        }
        return out
    }
}
