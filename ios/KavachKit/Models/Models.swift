import Foundation

/// SpacetimeDB timestamp on the wire: `[micros_since_unix_epoch]`; `[0]` means unset.
public struct STTimestamp: Codable, Sendable, Hashable, Comparable {
    public var micros: Int64
    public init(micros: Int64) { self.micros = micros }
    public init(date: Date) { micros = Int64(date.timeIntervalSince1970 * 1_000_000) }

    public var isSet: Bool { micros != 0 }
    public var date: Date? { isSet ? Date(timeIntervalSince1970: Double(micros) / 1_000_000) : nil }

    public init(from decoder: Decoder) throws {
        // Accept `[micros]` (SQL), `{"__timestamp_micros_since_unix_epoch__": n}` and a bare number.
        if var arr = try? decoder.unkeyedContainer() {
            micros = arr.isAtEnd ? 0 : try arr.decode(Int64.self)
        } else if let obj = try? decoder.container(keyedBy: AnyKey.self),
                  let k = obj.allKeys.first {
            micros = try obj.decode(Int64.self, forKey: k)
        } else {
            micros = try decoder.singleValueContainer().decode(Int64.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(micros)
    }

    public static func < (a: STTimestamp, b: STTimestamp) -> Bool { a.micros < b.micros }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var ownerHex: String
    public var phoneE164: String
    public var displayName: String
    public var accessibilityMode: Bool
    public var sharingPaused: Bool
    public var criticalOverridesPause: Bool
    public var practiceConsent: Bool
    public var apnsToken: String
    public var familyCodeWord: String
    public var tzOffsetMinutes: Int32
    public var recoveryWatchUntil: STTimestamp
    public var campaignWatchUntil: STTimestamp
    public var createdAt: STTimestamp
}

public enum ContactChannel: String, Codable, Sendable, CaseIterable {
    case imessage, sms, rcs, whatsapp
    public var label: String {
        switch self {
        case .imessage: "iMessage"
        case .sms: "Text (SMS)"
        case .rcs: "RCS"
        case .whatsapp: "WhatsApp"
        }
    }
}

public struct Contact: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var personId: UInt64
    public var name: String
    public var phoneE164: String
    public var relationship: String
    public var channel: String
    public var isEmergencyContact: Bool
    public var isAppUser: Bool
    public var linkedPersonId: UInt64
    public var consentStatus: String // invited | accepted | declined

    public var channelKind: ContactChannel? { ContactChannel(rawValue: channel) }
}

public enum Severity: String, Codable, Sendable, Comparable {
    case unrated = "", low, medium, high, critical
    var rank: Int { [.unrated: 0, .low: 1, .medium: 2, .high: 3, .critical: 4][self]! }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    public var label: String {
        switch self {
        case .unrated: "Not rated yet"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        }
    }
}

public struct Incident: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var requestKey: String
    public var personId: UInt64
    public var entryPoint: String
    public var callerE164: String
    public var claimedIdentity: String
    public var answersJson: String
    public var tactics: [String]
    public var sharedItems: [String]
    public var severity: String
    public var status: String // open | in_progress | resolved
    public var familyAckBy: UInt64
    public var campaignId: UInt64
    public var createdAt: STTimestamp
    public var resolvedAt: STTimestamp

    public var severityLevel: Severity { Severity(rawValue: severity) ?? .unrated }
    public var isResolved: Bool { status == "resolved" }
    public var answers: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(answersJson.utf8))) ?? [:]
    }
}

public struct RecoveryStep: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var incidentId: UInt64
    public var stepKey: String
    public var priority: String // now | today | this_week
    public var sortOrder: UInt32
    public var done: Bool

    public var priorityLabel: String {
        switch priority {
        case "now": "Do now"
        case "today": "Today"
        default: "This week"
        }
    }
}

public struct MessageCheck: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var requestKey: String
    public var personId: UInt64
    public var source: String
    public var contentRedacted: String
    public var verdict: String
    public var reason: String
    public var campaignId: UInt64
    public var evidenceCount: UInt32
    public var createdAt: STTimestamp

    public var verdictKind: Verdict { Verdict(wire: verdict) }
}

public struct Briefing: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var personId: UInt64
    public var weekStart: STTimestamp
    public var summaryText: String
    public var spokenText: String
    public var createdAt: STTimestamp
}

public struct Drill: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var personId: UInt64
    public var scheduledByContactId: UInt64
    public var templateKey: String
    public var sendAt: STTimestamp
    public var outcome: String
}

public struct Verification: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var requestKey: String
    public var personId: UInt64
    public var contactId: UInt64
    public var kind: String
    public var status: String
    public var deadline: STTimestamp
    public var createdAt: STTimestamp
}

/// Public Call Directory feed (`caller_labels` view): number + reporter count only (D15).
public struct CallerLabel: Codable, Sendable, Hashable {
    public var value: String
    public var reporterCount: UInt32
    public init(value: String, reporterCount: UInt32) { self.value = value; self.reporterCount = reporterCount }

    /// "Likely scam: N reports"
    public var labelText: String { "Likely scam: \(reporterCount) report\(reporterCount == 1 ? "" : "s")" }

    /// CallKit wants the number as digits including the country code, e.g. 15555550199.
    public var callKitNumber: Int64? { Int64(value.filter(\.isNumber)) }
}

public struct Campaign: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var slug: String
    public var title: String
    public var tacticSummary: String
    public var sampleText: String
    public var weeklyReports: UInt32
}

/// The three verdict states. The UI always pairs a color, an icon and a word.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    case safe
    case suspicious
    case likelyScam = "likely_scam"

    /// Unknown values degrade to `suspicious` (the safe default).
    public init(wire: String) {
        self = Verdict(rawValue: wire.lowercased()) ?? .suspicious
    }

    public var word: String {
        switch self {
        case .safe: "Looks safe"
        case .suspicious: "Suspicious"
        case .likelyScam: "Likely scam"
        }
    }

    public var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .suspicious: "exclamationmark.triangle.fill"
        case .likelyScam: "xmark.octagon.fill"
        }
    }
}
