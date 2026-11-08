import Foundation

/// Everything the Network dashboard shows, computed from data the app can read (`my_checks`,
/// `my_incidents`, `my_alert_requests`, `my_contacts`, `my_briefings`, public `campaign`).
/// Pure value type so it is unit-tested; the view only lays it out.
public struct NetworkDashboard: Sendable, Equatable {
    // MARK: KPIs

    public let messagesChecked: Int
    /// Likely-scam messages plus calls where nothing important was shared (Low/Medium).
    public let scamsStopped: Int
    public let response: FamilyReplies.ResponseStats
    /// Sum of `campaign.weekly_reports` (the community's reports this week).
    public let communityReports: Int

    // MARK: Chart

    public struct Day: Sendable, Equatable, Identifiable {
        public let start: Date
        public var safe = 0
        public var suspicious = 0
        public var likelyScam = 0
        public var id: Date { start }
        public var total: Int { safe + suspicious + likelyScam }
        public func count(_ v: Verdict) -> Int {
            switch v { case .safe: safe; case .suspicious: suspicious; case .likelyScam: likelyScam }
        }
    }
    /// Seven days, oldest first, ending today.
    public let days: [Day]

    // MARK: Network

    public struct FamilyNode: Sendable, Equatable, Identifiable {
        public let contact: Contact
        public let status: FamilyReplies.MemberStatus
        public var id: UInt64 { contact.id }
    }

    public struct ThreatNode: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case message, call }
        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String
        public let date: Date?
        public let campaignId: UInt64
        /// Danger only for "Likely scam" or Critical.
        public let isSevere: Bool
    }

    public struct CampaignNode: Sendable, Equatable, Identifiable {
        public let campaign: Campaign
        /// 0…1 relative to the largest campaign shown (node size).
        public let weight: Double
        public let linkedThreats: Int
        public var id: UInt64 { campaign.id }
    }

    /// A family member who was alerted about a threat (an incident's help/alert request), and whether
    /// they answered. These are the cross-links that make the map a network rather than a tree.
    public struct AlertLink: Sendable, Equatable, Hashable {
        public let familyId: UInt64
        public let threatId: String
        public let answered: Bool
    }

    public let family: [FamilyNode]
    public let threats: [ThreatNode]
    public let campaigns: [CampaignNode]
    public let alertLinks: [AlertLink]

    // MARK: Cards

    public let incidents: [Incident]
    public let briefings: [Briefing]

    public init(checks: [MessageCheck], incidents: [Incident], alertRequests: [AlertRequest], contacts: [Contact],
                campaigns: [Campaign], briefings: [Briefing], now: Date = Date(), calendar: Calendar = .current,
                maxThreats: Int = 8, maxCampaigns: Int = 4) {
        let weekStart = calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
        func inWeek(_ t: STTimestamp) -> Bool { (t.date ?? .distantPast) >= weekStart }

        let weekChecks = checks.filter { inWeek($0.createdAt) }
        let weekIncidents = incidents.filter { inWeek($0.createdAt) }
        messagesChecked = weekChecks.count
        scamsStopped = weekChecks.filter { $0.verdictKind == .likelyScam }.count
            + weekIncidents.filter { $0.severityLevel == .low || $0.severityLevel == .medium }.count

        let weekRequests = alertRequests.filter { inWeek($0.createdAt) }
        response = FamilyReplies.stats(weekRequests.isEmpty ? alertRequests : weekRequests)
        communityReports = campaigns.reduce(0) { $0 + Int($1.weeklyReports) }

        var buckets = (0..<7).map { Day(start: calendar.date(byAdding: .day, value: $0, to: weekStart)!) }
        for c in weekChecks {
            guard let d = c.createdAt.date else { continue }
            let day = calendar.startOfDay(for: d)
            guard let i = buckets.firstIndex(where: { $0.start == day }) else { continue }
            switch c.verdictKind {
            case .safe: buckets[i].safe += 1
            case .suspicious: buckets[i].suspicious += 1
            case .likelyScam: buckets[i].likelyScam += 1
            }
        }
        days = buckets

        family = contacts.map { FamilyNode(contact: $0, status: FamilyReplies.memberStatus($0, in: alertRequests)) }

        // Threats blocked this week: messages that weren't safe, and calls the person reported.
        var t: [ThreatNode] = weekChecks.filter { $0.verdictKind != .safe }.map { c in
            ThreatNode(id: "check-\(c.id)", kind: .message,
                       title: c.verdictKind == .likelyScam ? "Scam message" : "Suspicious message",
                       detail: c.reason, date: c.createdAt.date, campaignId: c.campaignId,
                       isSevere: c.verdictKind == .likelyScam)
        }
        t += weekIncidents.map { i in
            ThreatNode(id: "incident-\(i.id)", kind: .call,
                       title: i.entryPoint == "companion" ? "Call (you asked for help)" : "Reported call",
                       detail: i.claimedIdentity.isEmpty ? "Level: \(i.severityLevel.label)" : "Said they were: \(i.claimedIdentity)",
                       date: i.createdAt.date, campaignId: i.campaignId, isSevere: i.severityLevel == .critical)
        }
        threats = Array(t.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(maxThreats))

        // Campaigns: the ones this person's threats belong to first, then the most reported.
        let linked = Dictionary(grouping: threats.filter { $0.campaignId != 0 }, by: \.campaignId).mapValues(\.count)
        let ordered = campaigns.sorted { a, b in
            let la = linked[a.id] ?? 0, lb = linked[b.id] ?? 0
            return la != lb ? la > lb : a.weeklyReports > b.weeklyReports
        }.prefix(maxCampaigns)
        let maxReports = max(1, ordered.map(\.weeklyReports).max() ?? 1)
        self.campaigns = ordered.map {
            CampaignNode(campaign: $0, weight: Double($0.weeklyReports) / Double(maxReports), linkedThreats: linked[$0.id] ?? 0)
        }

        let threatIds = Set(threats.map(\.id)), familyIds = Set(contacts.map(\.id))
        var links = Set<AlertLink>()
        for r in alertRequests where r.incidentId != 0 && r.kind != "verify" {
            let tid = "incident-\(r.incidentId)"
            guard threatIds.contains(tid) else { continue }
            for cid in r.recipientContactIds where familyIds.contains(cid) {
                links.insert(AlertLink(familyId: cid, threatId: tid,
                                       answered: r.status == "acknowledged" && r.ackedByContactId == cid))
            }
        }
        // An answered link wins over an unanswered one for the same pair.
        alertLinks = links.filter { l in l.answered || !links.contains(AlertLink(familyId: l.familyId, threatId: l.threatId, answered: true)) }
            .sorted { ($0.familyId, $0.threatId) < ($1.familyId, $1.threatId) }

        self.incidents = incidents.sorted { $0.createdAt > $1.createdAt }
        self.briefings = briefings.sorted { $0.createdAt > $1.createdAt }
    }

    /// "3 safe, 2 suspicious, 1 likely scam" for the week (chart summary, VoiceOver).
    public var weekSummary: String {
        let s = days.reduce(0) { $0 + $1.safe }, q = days.reduce(0) { $0 + $1.suspicious }, l = days.reduce(0) { $0 + $1.likelyScam }
        if s + q + l == 0 { return "No messages checked in the last 7 days." }
        return "\(s) looked safe, \(q) suspicious, \(l) likely scam."
    }

    /// "2 of 3 replied · usually within 4 min" (KPI detail).
    public var responseDetail: String {
        guard response.asked > 0 else { return "No requests yet" }
        var s = "\(response.answered) of \(response.asked) answered"
        if let m = response.medianMinutes { s += " · usually in \(m == 0 ? "under a" : "\(m)") min" }
        return s
    }

    /// "67%" or "–".
    public var responseRateText: String {
        guard let r = response.rate else { return "–" }
        return "\(Int((r * 100).rounded()))%"
    }
}
