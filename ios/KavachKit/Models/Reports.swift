import CryptoKit
import Foundation

/// "Your reports": every incident the person has (app, Recents, Call Companion, by text), as rows.
/// Pure mapping from `my_incidents` so it is unit-tested; the views only lay it out.
public struct ReportSummary: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Equatable {
        case app, recents, companion, text

        public var label: String {
            switch self {
            case .app: "Reported from the app"
            case .recents: "From Recents"
            case .companion: "During a call"
            case .text: "By text"
            }
        }

        public var symbol: String {
            switch self {
            case .app: "iphone"
            case .recents: "phone.arrow.down.left"
            case .companion: "phone"
            case .text: "message"
            }
        }
    }

    public enum Status: Sendable, Equatable {
        /// The questionnaire isn't finished (no `q_shared` answer yet).
        case unfinished
        /// Answered; steps may still be open.
        case open
        case resolved
        /// A call the person didn't answer (`q_answered` = no): finished, Low, number still reported.
        case missed

        public var label: String {
            switch self {
            case .unfinished: "Not finished"
            case .open: "Answered"
            case .resolved: "Done"
            case .missed: "Missed call"
            }
        }
    }

    public let id: UInt64
    public let incident: Incident
    public let source: Source
    /// "+1 (415) 555-0199", or "Number not given".
    public let callerText: String
    public let hasCaller: Bool
    public let date: Date?
    public let severity: Severity
    public let status: Status
    /// Whether this report's interview starts with "Did you answer the call?" (call reports).
    public let asksAnswered: Bool
    /// Index into `InterviewScript.questions(askAnswered:)` of the first unanswered question; nil when
    /// the interview is complete (every question answered, or a missed call).
    public let resumeIndex: Int?

    public var isUnfinished: Bool { status == .unfinished }
    public var isMissedCall: Bool { status == .missed }

    /// The question the interview resumes at, if it isn't complete.
    public var resumeQuestion: InterviewQuestion? {
        resumeIndex.map { InterviewScript.questions(askAnswered: asksAnswered)[$0] }
    }

    /// Core questions still to answer ("Did you answer the call?" isn't counted).
    public var questionsLeft: Int {
        guard let q = resumeQuestion else { return 0 }
        let core = InterviewScript.questions
        return core.count - (core.firstIndex { $0.id == q.id } ?? 0)
    }

    /// One line for the reports list: "Missed call · Low", "Answered · High"…
    public var listLabel: String { "\(status.label) · \(severity.label)" }

    public init(_ inc: Incident) {
        id = inc.id
        incident = inc
        source = ReportsList.source(of: inc)
        hasCaller = !inc.callerE164.isEmpty
        callerText = hasCaller ? PhoneNumbers.formatted(inc.callerE164) : "Number not given"
        date = inc.createdAt.date
        severity = inc.severityLevel
        let answers = inc.answers
        asksAnswered = ReportsList.asksAnswered(inc)
        resumeIndex = ReportsList.firstUnanswered(answers, askAnswered: asksAnswered)
        if ReportsList.isMissedCall(answers) { status = .missed }
        else if inc.isResolved { status = .resolved }
        else if answers["q_shared"] == nil { status = .unfinished }
        else { status = .open }
    }

    /// "Who called, from where, level, status" for VoiceOver.
    public var accessibilityText: String {
        var parts = [hasCaller ? "Call from \(callerText)" : "Call, number not given", source.label]
        if let date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if isMissedCall {
            parts.append("Missed call. Level: \(severity.label)")
        } else {
            parts.append("Level: \(severity.label)")
            parts.append(status.label)
        }
        return parts.joined(separator: ". ")
    }
}

public enum ReportsList {
    /// Newest first.
    public static func make(_ incidents: [Incident]) -> [ReportSummary] {
        incidents.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.map(ReportSummary.init)
    }

    /// Open reports whose questionnaire isn't finished, newest first (Home banner).
    public static func unfinished(_ incidents: [Incident]) -> [ReportSummary] {
        make(incidents).filter(\.isUnfinished)
    }

    /// Plain-words origin. `report_swipe` is both the in-app Report-a-call flow and Recents; the in-app
    /// flow uses its own request-key prefix (`ReportDraft.keyPrefix`).
    public static func source(of inc: Incident) -> ReportSummary.Source {
        switch inc.entryPoint {
        case "companion": return .companion
        case "imessage": return .text
        case "report_swipe":
            return inc.requestKey.hasPrefix(ReportDraft.keyPrefix) ? .app : .recents
        default: return .app
        }
    }

    /// Reports about a call (in-app Report a call and Recents, both `report_swipe`) start with
    /// "Did you answer the call?". Call Companion reports were answered by definition.
    public static func asksAnswered(_ inc: Incident) -> Bool {
        inc.entryPoint == ReportDraft.entryPoint
    }

    /// The person said they didn't answer the call: the interview is complete at Low.
    public static func isMissedCall(_ answers: [String: String]) -> Bool {
        answers[InterviewScript.answeredQuestion.id] == "no"
    }

    /// Index (into `InterviewScript.questions(askAnswered:)`) of the first question to ask, or nil when
    /// the interview is complete. Call reports with no answers start at "Did you answer the call?";
    /// a missed call is complete; older call reports that already have core answers but no
    /// `q_answered` skip it and resume at their first unanswered core question.
    public static func firstUnanswered(_ answers: [String: String], askAnswered: Bool = false) -> Int? {
        let has: (String) -> Bool = { !(answers[$0] ?? "").isEmpty }
        let core = InterviewScript.questions.firstIndex { !has($0.id) }
        guard askAnswered else { return core }
        if isMissedCall(answers) { return nil }
        let anyCore = InterviewScript.questions.contains { has($0.id) }
        if !has(InterviewScript.answeredQuestion.id) && !anyCore { return 0 }
        return core.map { $0 + 1 }
    }
}

/// A report the person starts in the app ("Report a call"). The request key is derived from the
/// person, number and start time, so retrying `open_incident` never creates a second incident.
public struct ReportDraft: Sendable, Equatable {
    public static let keyPrefix = "ios-app-report-"

    public var personId: UInt64
    /// E.164, or "" when the person doesn't know the number.
    public var callerE164: String
    public var startedAtMicros: Int64

    public init(personId: UInt64, callerE164: String, startedAt: Date = Date()) {
        self.personId = personId
        self.callerE164 = callerE164
        self.startedAtMicros = STTimestamp(date: startedAt).micros
    }

    /// `ios-app-report-` + 40 hex chars of sha256("<person>|<caller>|<micros>") (55 chars, ≤ 64).
    public var requestKey: String {
        let digest = SHA256.hash(data: Data("\(personId)|\(callerE164)|\(startedAtMicros)".utf8))
        return Self.keyPrefix + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
    }

    public static let entryPoint = "report_swipe"
}

/// What the community knows about a number (from the public `caller_labels` feed).
public struct CallerReputation: Sendable, Equatable {
    /// `caller_labels` lists a number once this many people reported it (module LABEL_THRESHOLD).
    public static let likelyScamThreshold: UInt32 = 3

    public let reporterCount: UInt32

    public init?(e164: String, labels: [CallerLabel]) {
        guard !e164.isEmpty, let l = labels.first(where: { $0.value == e164 }), l.reporterCount > 0 else { return nil }
        reporterCount = l.reporterCount
    }

    /// Red only when the module's "likely scam" rule holds.
    public var isLikelyScam: Bool { reporterCount >= Self.likelyScamThreshold }

    public var text: String {
        reporterCount == 1 ? "1 person has reported this number as a scam"
                           : "\(reporterCount) people have reported this number as a scam"
    }
}

/// Saves interview answers for a report and files the number at the end. Shared by the in-app
/// flow; tests drive it with a fake backend.
public enum ReportFiling {
    /// Opens (or finds, by request key) the incident for a draft.
    public static func open(_ draft: ReportDraft, backend: CallReportBackend) async throws -> Incident {
        try await backend.openIncident(requestKey: draft.requestKey, personId: draft.personId,
                                       entryPoint: ReportDraft.entryPoint, callerE164: draft.callerE164)
    }

    /// After the last answer: report the number to the community (when one was given).
    public static func finish(personId: UInt64, callerE164: String, backend: CallReportBackend) async throws {
        guard !callerE164.isEmpty else { return }
        try await backend.reportValue(personId: personId, kind: "number", value: callerE164)
    }
}

/// One answered question in a report's summary ("What they asked: Yes, they asked").
public struct ReportAnswerLine: Sendable, Equatable, Identifiable {
    public let questionId: String
    public let title: String
    public let answer: String
    public var id: String { questionId }
}

public extension ReportsList {
    /// Short titles for the five questions (summary screen).
    static let answerTitles: [String: String] = [
        "q_answered": "Did you answer the call",
        "q_identity": "Who they said they were",
        "q_ask": "What they asked for",
        "q_shared": "What you shared",
        "q_secrecy": "Told to keep it secret or hurry",
        "q_help": "Family help",
    ]

    /// Answered questions in interview order, with wire values turned back into the words the
    /// person chose. Unanswered questions are left out.
    static func answerLines(_ answers: [String: String]) -> [ReportAnswerLine] {
        InterviewScript.questions(askAnswered: true).compactMap { q in
            guard let wire = answers[q.id], !wire.isEmpty else { return nil }
            return ReportAnswerLine(questionId: q.id, title: answerTitles[q.id] ?? q.prompt, answer: answerText(q, wire))
        }
    }

    static func answerText(_ q: InterviewQuestion, _ wire: String) -> String {
        switch q.kind {
        case .text: return wire
        case .single(let opts): return opts.first { $0.value == wire }?.label ?? wire
        case .multi(let opts, _):
            let parts = wire.split(separator: ",").map { v in
                opts.first { $0.value == String(v) }?.label ?? String(v)
            }
            return parts.joined(separator: "; ")
        }
    }
}

/// "Your reports", segmented for the person: what still needs their answers, what's answered with
/// steps still open, and what's done. Empty groups are left out; order inside each is newest first.
public struct ReportSection: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case needsAnswers, answered, done }
    public let kind: Kind
    public let reports: [ReportSummary]
    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .needsAnswers: "Needs your answers"
        case .answered: "Answered"
        case .done: "Done"
        }
    }

    public var detail: String {
        switch kind {
        case .needsAnswers: "Finish these so we can tell you what to do next."
        case .answered: "We have your answers. Some steps may still be open."
        case .done: "Closed reports, and calls you didn't pick up."
        }
    }

    public var symbol: String {
        switch kind {
        case .needsAnswers: "exclamationmark.circle"
        case .answered: "checkmark"
        case .done: "checkmark.circle.fill"
        }
    }

    public static func make(_ reports: [ReportSummary]) -> [ReportSection] {
        let sorted = reports.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let byKind: [Kind: [ReportSummary]] = Dictionary(grouping: sorted) { r in
            switch r.status { case .unfinished: .needsAnswers; case .open: .answered; case .resolved, .missed: .done }
        }
        return Kind.allCases.compactMap { k in
            guard let items = byKind[k], !items.isEmpty else { return nil }
            return ReportSection(kind: k, reports: items)
        }
    }
}
