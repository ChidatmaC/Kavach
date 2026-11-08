import Foundation

/// A family notification that needs a reply (`my_alert_requests`, docs/CONTRACTS.md section 7).
public struct AlertRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var personId: UInt64
    public var incidentId: UInt64
    public var verificationId: UInt64
    /// help | alert | verify
    public var kind: String
    public var recipientContactIds: [UInt64]
    /// pending | acknowledged | unanswered
    public var status: String
    public var ackedByContactId: UInt64
    public var remindersSent: UInt8
    public var lastBody: String
    public var createdAt: STTimestamp
    public var deadline: STTimestamp
    public var resolvedAt: STTimestamp

    public init(id: UInt64, personId: UInt64 = 0, incidentId: UInt64 = 0, verificationId: UInt64 = 0, kind: String,
                recipientContactIds: [UInt64], status: String, ackedByContactId: UInt64 = 0, remindersSent: UInt8 = 0,
                lastBody: String = "", createdAt: STTimestamp, deadline: STTimestamp = STTimestamp(micros: 0),
                resolvedAt: STTimestamp = STTimestamp(micros: 0)) {
        self.id = id; self.personId = personId; self.incidentId = incidentId; self.verificationId = verificationId
        self.kind = kind; self.recipientContactIds = recipientContactIds; self.status = status
        self.ackedByContactId = ackedByContactId; self.remindersSent = remindersSent; self.lastBody = lastBody
        self.createdAt = createdAt; self.deadline = deadline; self.resolvedAt = resolvedAt
    }

    public enum Kind: String, Sendable { case help, alert, verify }
    public var kindValue: Kind { Kind(rawValue: kind) ?? .alert }

    /// What the app shows: waiting, waiting after a reminder (urgent), acknowledged, or no reply (urgent).
    public enum Phase: Sendable, Equatable { case waiting, reminded, acknowledged, unanswered }

    public var phase: Phase {
        switch status {
        case "acknowledged": .acknowledged
        case "unanswered": .unanswered
        default: remindersSent > 0 ? .reminded : .waiting
        }
    }

    /// Calls for action: no one has answered after the first window.
    public var isUrgent: Bool { phase == .reminded || phase == .unanswered }
    public var isOpen: Bool { phase == .waiting || phase == .reminded }
}

/// Wording and choices for family replies. Pure functions so every screen says the same thing.
public enum FamilyReplies {
    /// "Tommy", "Tommy and Maria", "Tommy, Maria and Sam".
    public static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: "your family"
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// Short first names read better in banners ("Tommy" rather than "Tommy Rivera").
    public static func shortName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    public static func recipients(of r: AlertRequest, in contacts: [Contact]) -> [Contact] {
        r.recipientContactIds.compactMap { id in contacts.first { $0.id == id } }
    }

    /// Who to call when nobody answered: an emergency contact among the recipients, else the first
    /// recipient, else any emergency contact.
    public static func callTarget(for r: AlertRequest, in contacts: [Contact]) -> Contact? {
        let rec = recipients(of: r, in: contacts)
        return rec.first(where: \.isEmergencyContact) ?? rec.first ?? contacts.first(where: \.isEmergencyContact)
    }

    public static func ackedBy(_ r: AlertRequest, in contacts: [Contact]) -> Contact? {
        guard r.ackedByContactId != 0 else { return nil }
        return contacts.first { $0.id == r.ackedByContactId }
    }

    /// One-line headline for the request.
    public static func headline(_ r: AlertRequest, contacts: [Contact]) -> String {
        let names = recipients(of: r, in: contacts).map { shortName($0.name) }
        let who = joinNames(names)
        let callName = callTarget(for: r, in: contacts).map { shortName($0.name) }
        switch r.phase {
        case .waiting:
            return r.kindValue == .verify ? "Waiting for \(who) to confirm…" : "Waiting for \(who) to reply…"
        case .reminded:
            return callName.map { "No reply yet from \(who). Call \($0)." } ?? "No reply yet from \(who)."
        case .unanswered:
            return callName.map { "No reply from your family. Call \($0)." } ?? "No reply from your family."
        case .acknowledged:
            let name = ackedBy(r, in: contacts).map { shortName($0.name) } ?? (names.first ?? "Your family")
            return r.kindValue == .verify ? "\(name) answered" : "\(name) saw it"
        }
    }

    /// Supporting sentence for the request.
    public static func detail(_ r: AlertRequest) -> String {
        switch (r.kindValue, r.phase) {
        case (.verify, .unanswered): "They never confirmed. Treat the message as a scam and don't send anything."
        case (.verify, .acknowledged): "They answered your check."
        case (.verify, _): "We asked them whether the message really came from them. Don't send anything until they answer."
        case (.help, .acknowledged): "They know you asked for help during a call."
        case (.help, .unanswered), (.alert, .unanswered): "Please call them yourself now."
        case (.help, _): "We told them you asked for help during a call."
        case (.alert, .acknowledged): "They know about the scam alert."
        case (.alert, _): "We sent them a scam alert."
        }
    }

    /// Requests worth showing now, newest first: anything still open or unanswered from the last
    /// day, plus acknowledgements from the last `ackWindow` seconds.
    public static func relevant(_ requests: [AlertRequest], now: Date = Date(), ackWindow: TimeInterval = 30 * 60) -> [AlertRequest] {
        let dayAgo = now.addingTimeInterval(-86_400)
        return requests.filter { r in
            let created = r.createdAt.date ?? .distantPast
            switch r.phase {
            case .waiting, .reminded, .unanswered: return created >= dayAgo
            case .acknowledged: return (r.resolvedAt.date ?? created) >= now.addingTimeInterval(-ackWindow)
            }
        }
        .sorted { a, b in
            if a.isUrgent != b.isUrgent { return a.isUrgent }
            return a.createdAt > b.createdAt
        }
    }

    /// The most recent request for one incident (Call Companion, Act now).
    public static func latest(for incidentId: UInt64, in requests: [AlertRequest]) -> AlertRequest? {
        requests.filter { $0.incidentId == incidentId }.max { $0.createdAt < $1.createdAt }
    }

    /// Steps for the Call Companion status line: "Told" → "Seen by Tommy".
    public struct Progress: Sendable, Equatable {
        public let told: Bool
        public let seenBy: String?
        public let urgent: Bool
        public let text: String
    }

    public static func progress(for r: AlertRequest?, contacts: [Contact], sharingPaused: Bool) -> Progress {
        guard let r else {
            return sharingPaused
                ? Progress(told: false, seenBy: nil, urgent: false, text: "Family alerts are paused, so your family wasn't told.")
                : Progress(told: false, seenBy: nil, urgent: false, text: "Telling your family…")
        }
        let who = joinNames(recipients(of: r, in: contacts).map { shortName($0.name) })
        switch r.phase {
        case .acknowledged:
            let name = ackedBy(r, in: contacts).map { shortName($0.name) } ?? who
            return Progress(told: true, seenBy: name, urgent: false, text: "\(name) saw it and knows you asked for help.")
        case .waiting:
            return Progress(told: true, seenBy: nil, urgent: false, text: "Told \(who). Waiting for a reply…")
        case .reminded, .unanswered:
            return Progress(told: true, seenBy: nil, urgent: true, text: headline(r, contacts: contacts))
        }
    }

    // MARK: Response stats (dashboard)

    public struct ResponseStats: Sendable, Equatable {
        public let asked: Int
        public let answered: Int
        public let unanswered: Int
        public let pending: Int
        /// Median minutes from request to acknowledgement, when any were answered.
        public let medianMinutes: Int?
        public var rate: Double? { asked == 0 ? nil : Double(answered) / Double(asked) }
    }

    public static func stats(_ requests: [AlertRequest]) -> ResponseStats {
        let answered = requests.filter { $0.phase == .acknowledged }
        let times = answered.compactMap { r -> Double? in
            guard let a = r.createdAt.date, let b = r.resolvedAt.date else { return nil }
            return max(0, b.timeIntervalSince(a)) / 60
        }.sorted()
        let median: Int? = times.isEmpty ? nil : Int((times.count % 2 == 1
            ? times[times.count / 2]
            : (times[times.count / 2 - 1] + times[times.count / 2]) / 2).rounded())
        return ResponseStats(asked: requests.count, answered: answered.count,
                             unanswered: requests.filter { $0.phase == .unanswered }.count,
                             pending: requests.filter(\.isOpen).count, medianMinutes: median)
    }

    /// Per family member: how they last responded (network map node color + label).
    public enum MemberStatus: String, Sendable, Equatable { case replied, waiting, noReply, none }

    public static func memberStatus(_ contact: Contact, in requests: [AlertRequest]) -> MemberStatus {
        let mine = requests.filter { $0.recipientContactIds.contains(contact.id) }.sorted { $0.createdAt > $1.createdAt }
        guard let last = mine.first else { return .none }
        switch last.phase {
        case .acknowledged: return last.ackedByContactId == contact.id ? .replied : .none
        case .waiting, .reminded: return .waiting
        case .unanswered: return .noReply
        }
    }
}
