import Charts
import KavachKit
import SwiftUI

/// "Network": the person's protection network this week. KPIs, a map of family and blocked threats
/// linked to the scam campaigns they belong to (with a list alternative), checks per day, reports
/// and the weekly briefing. Everything comes from the polled views; nothing is computed server-side here.
struct NetworkDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var mode: Mode = .map
    @State private var selection: NetworkNodeID? = .you

    enum Mode: String, CaseIterable { case map = "Map", list = "List" }

    var body: some View {
        let d = model.dashboard
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ReportsSection()

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionTitle("This week", detail: "Last 7 days")
                    kpis(d)
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle("Your network", detail: "Who protects you, and what was stopped")
                        Picker("View as", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 160)
                    }
                    if mode == .map && !voiceOver {
                        Card(padding: Theme.Space.s) {
                            NetworkGraphView(dashboard: d, name: model.person?.displayName ?? "You",
                                             photos: model.contactsBridge.photos, selection: $selection)
                            NetworkLegend()
                        }
                        NetworkNodeDetail(dashboard: d, selection: selection)
                    } else {
                        NetworkListView(dashboard: d)
                    }
                }
                .id("network-map")

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionTitle("Messages checked", detail: d.weekSummary)
                    Card { ChecksChart(days: d.days) }
                }

                BriefingCard(briefing: d.briefings.first)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.xl)
        }
        .debugScrollAnchor()
        #if DEBUG
        .task {
            // Screenshot helper: KAVACH_DEBUG_SCROLL=map lands on the network map.
            guard ProcessInfo.processInfo.environment["KAVACH_DEBUG_SCROLL"] == "map" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            proxy.scrollTo("network-map", anchor: .top)
        }
        #endif
        }
        .kavachScreenBackground()
        .navigationTitle("Network")
        .refreshable { await model.refresh(); await model.refreshLabelsAndCampaigns() }
    }

    @ViewBuilder private func kpis(_ d: NetworkDashboard) -> some View {
        let tiles = [
            KPITile(value: "\(d.messagesChecked)", label: "Messages checked", detail: "By you, this week",
                    systemImage: "text.magnifyingglass"),
            KPITile(value: "\(d.scamsStopped)", label: "Scams stopped", detail: "Messages and calls",
                    systemImage: "checkmark.shield", tone: .success),
            KPITile(value: d.responseRateText, label: "Family replies", detail: d.responseDetail,
                    systemImage: "person.2", tone: d.response.unanswered > 0 ? .caution : .info),
            KPITile(value: "\(d.communityReports)", label: "Community reports", detail: "Scams reported by others",
                    systemImage: "person.3"),
        ]
        if typeSize.isAccessibilitySize {
            VStack(spacing: Theme.Space.s) { ForEach(0..<4, id: \.self) { tiles[$0] } }
        } else {
            Grid(horizontalSpacing: Theme.Space.s, verticalSpacing: Theme.Space.s) {
                GridRow { tiles[0]; tiles[1] }
                GridRow { tiles[2]; tiles[3] }
            }
        }
    }
}

// MARK: Graph

enum NetworkNodeID: Hashable {
    case you, family(UInt64), threat(String), campaign(UInt64)
}

/// The protection network as a radial graph. "You" sit at the hub; family members orbit closest,
/// threats blocked this week sit on the middle orbit grouped by the scam campaign they belong to, and
/// campaigns sit on the outer orbit beside their threats (sized by community reports). Curved links
/// connect everything, including which family members were alerted about which threat. Selecting a
/// node highlights its connections and dims the rest. Every node is a 44-pt button.
struct NetworkGraphView: View {
    let dashboard: NetworkDashboard
    let name: String
    let photos: [UInt64: Data]
    @Binding var selection: NetworkNodeID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    private let height: CGFloat = 420

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(dashboard: dashboard, size: geo.size)
            let focus = layout.connected(to: selection)
            ZStack {
                Canvas { ctx, _ in
                    drawOrbits(ctx, layout)
                    // Dimmed links first, highlighted ones on top.
                    for e in layout.edges where !focus.edgeIds.contains(e.id) { draw(e, ctx, highlighted: false, dimmed: !focus.isEmpty) }
                    for e in layout.edges where focus.edgeIds.contains(e.id) { draw(e, ctx, highlighted: true, dimmed: false) }
                }
                .accessibilityHidden(true)

                nodeButton(.you, at: layout.you, label: "You, \(name)", dimmed: false) { YouNode(pulse: !reduceMotion) }
                ForEach(dashboard.family) { f in
                    if let p = layout.family[f.id] {
                        nodeButton(.family(f.id), at: p, label: "\(f.contact.name), \(statusText(f.status))",
                                   dimmed: !focus.isEmpty && !focus.nodes.contains(.family(f.id))) {
                            FamilyNode(node: f, photo: photos[f.id])
                        }
                    }
                }
                ForEach(dashboard.threats) { t in
                    if let p = layout.threats[t.id] {
                        nodeButton(.threat(t.id), at: p, label: "\(t.title). \(t.detail)",
                                   dimmed: !focus.isEmpty && !focus.nodes.contains(.threat(t.id))) { ThreatNodeView(threat: t) }
                    }
                }
                ForEach(dashboard.campaigns) { c in
                    if let p = layout.campaigns[c.id] {
                        nodeButton(.campaign(c.id), at: p,
                                   label: "Scam campaign: \(c.campaign.title), \(c.campaign.weeklyReports) reports this week",
                                   dimmed: !focus.isEmpty && !focus.nodes.contains(.campaign(c.id))) {
                            CampaignNodeView(node: c)
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: selection)
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 0.6)) { drawn = 1 } }
        }
    }

    // MARK: Drawing

    private func drawOrbits(_ ctx: GraphicsContext, _ l: Layout) {
        // Soft hub halo, then three thin orbit rings: family, threats, campaigns.
        let hr = min(l.oFamily.rx, l.oFamily.up) * 0.7
        let halo = Path(ellipseIn: CGRect(x: l.you.x - hr, y: l.you.y - hr, width: hr * 2, height: hr * 2))
        ctx.fill(halo, with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.14), Theme.accent.opacity(0)]),
                                             center: l.you, startRadius: 0, endRadius: hr))
        for (o, dash) in [(l.oFamily, [CGFloat]()), (l.oThreat, [2, 5]), (l.oCampaign, [1, 6])] {
            var ring = Path()
            for deg in stride(from: 0.0, through: 360.0, by: 3) {
                let q = l.point(deg, o)
                if deg == 0 { ring.move(to: q) } else { ring.addLine(to: q) }
            }
            ring.closeSubpath()
            ctx.stroke(ring, with: .color(Theme.separator.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: dash))
        }
    }

    private func draw(_ e: Layout.Edge, _ ctx: GraphicsContext, highlighted: Bool, dimmed: Bool) {
        var p = Path()
        p.move(to: e.from)
        p.addQuadCurve(to: e.to, control: e.control)
        let trimmed = p.trimmedPath(from: 0, to: drawn)
        let alpha = dimmed ? 0.18 : (highlighted ? 1 : e.baseOpacity)
        let width = highlighted ? e.width + 1.2 : e.width
        ctx.stroke(trimmed,
                   with: .linearGradient(Gradient(colors: [e.fromColor.opacity(alpha), e.toColor.opacity(alpha)]),
                                         startPoint: e.from, endPoint: e.to),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, dash: e.dashed ? [5, 5] : []))
        if highlighted && !e.dashed {
            // A small dot at the far end shows direction (who is connected to whom).
            let dot = Path(ellipseIn: CGRect(x: e.to.x - 3, y: e.to.y - 3, width: 6, height: 6))
            ctx.fill(dot, with: .color(e.toColor))
        }
    }

    private func nodeButton<V: View>(_ id: NetworkNodeID, at p: CGPoint, label: String, dimmed: Bool,
                                     @ViewBuilder content: () -> V) -> some View {
        Button { selection = (selection == id && id != .you) ? .you : id } label: {
            content()
                .padding(4)
                .background {
                    if selection == id && id != .you {
                        Circle().fill(Theme.accent.opacity(0.12)).scaleEffect(1.25)
                    }
                }
                .overlay {
                    if selection == id && id != .you {
                        Circle().strokeBorder(Theme.accent, lineWidth: 2).scaleEffect(1.25)
                    }
                }
                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .opacity(dimmed ? 0.35 : 1)
        .position(p)
        .accessibilityLabel(label)
        .accessibilityHint("Shows details below the map")
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    private func statusText(_ s: FamilyReplies.MemberStatus) -> String {
        switch s {
        case .replied: "replied"
        case .waiting: "waiting for a reply"
        case .noReply: "no reply"
        case .none: "no requests yet"
        }
    }

    // MARK: Layout

    /// Node positions and curved edges for a given size. Pure geometry.
    struct Layout {
        struct Edge: Identifiable {
            let id: String
            let a: NetworkNodeID, b: NetworkNodeID
            let from: CGPoint, to: CGPoint, control: CGPoint
            let fromColor: Color, toColor: Color
            let width: CGFloat, dashed: Bool, baseOpacity: Double
        }
        struct Focus {
            var nodes: Set<NetworkNodeID> = []
            var edgeIds: Set<String> = []
            var isEmpty: Bool { nodes.isEmpty }
        }

        var you: CGPoint
        /// An orbit: horizontal radius, and separate radii above and below the hub (family live above,
        /// threats and campaigns below), so the graph fills the card instead of a centred circle.
        struct Orbit { var rx: CGFloat, up: CGFloat, down: CGFloat }
        var oFamily = Orbit(rx: 0, up: 0, down: 0), oThreat = Orbit(rx: 0, up: 0, down: 0), oCampaign = Orbit(rx: 0, up: 0, down: 0)

        func point(_ deg: Double, _ o: Orbit) -> CGPoint {
            let rad = deg * .pi / 180
            let sy = CGFloat(sin(rad))
            return CGPoint(x: you.x + o.rx * CGFloat(cos(rad)), y: you.y + (sy < 0 ? o.up : o.down) * sy)
        }
        var family: [UInt64: CGPoint] = [:]
        var threats: [String: CGPoint] = [:]
        var campaigns: [UInt64: CGPoint] = [:]
        var edges: [Edge] = []

        init(dashboard d: NetworkDashboard, size: CGSize) {
            let w = size.width, h = size.height
            you = CGPoint(x: w / 2, y: h * 0.34)
            let rx = w / 2 - 40
            let up = you.y - 44            // room for family names above their avatars
            let down = h - you.y - 64      // room for two-line campaign labels below their circles
            oFamily = Orbit(rx: rx * 0.58, up: up * 0.86, down: down * 0.30)
            oThreat = Orbit(rx: rx * 0.80, up: up * 0.95, down: down * 0.52)
            oCampaign = Orbit(rx: rx * 1.0, up: up * 1.0, down: down * 0.98)
            let point = self.point
            func spread(_ n: Int, _ a: Double, _ b: Double) -> [Double] {
                guard n > 1 else { return [(a + b) / 2] }
                return (0..<n).map { a + (b - a) * Double($0) / Double(n - 1) }
            }

            // Family across the upper half of the inner orbit (-90° is straight up).
            let fn = d.family.count
            let fSpan = fn <= 1 ? 0 : min(160, Double(fn - 1) * 70)
            for (f, a) in zip(d.family, spread(fn, -90 - fSpan / 2, -90 + fSpan / 2)) { family[f.id] = point(a, oFamily) }

            // Threats on the middle orbit, lower half, grouped into campaign sectors so links stay short.
            let groups = Dictionary(grouping: d.threats, by: \.campaignId)
            let order = d.campaigns.map(\.id).filter { groups[$0] != nil } + (groups[0] != nil ? [0] : [])
                + groups.keys.filter { $0 != 0 && !d.campaigns.map(\.id).contains($0) }.sorted()
            let tAngles = spread(d.threats.count, d.threats.count > 5 ? 8 : 25, d.threats.count > 5 ? 172 : 155)
            var i = 0
            var sectorAngle: [UInt64: Double] = [:]
            for cid in order {
                let members = groups[cid] ?? []
                var sum = 0.0
                for t in members { let a = tAngles[i]; threats[t.id] = point(a, oThreat); sum += a; i += 1 }
                if !members.isEmpty { sectorAngle[cid] = sum / Double(members.count) }
            }

            // Campaigns on the outer orbit beside their threats; unlinked ones fill the sides.
            var used: [Double] = []
            var free = [170.0, 10.0, 150.0, 30.0, 190.0, -10.0]
            for c in d.campaigns {
                // Keep campaigns in the lower arc, below the threat ring, so they never sit beside a threat.
                var a = min(max(sectorAngle[c.id] ?? free.removeFirst(), 38), 142)
                // Keep campaign labels from colliding (at least 34° apart).
                while used.contains(where: { abs($0 - a) < 30 }) { a += (a < 90 ? -10 : 10) }
                used.append(a)
                campaigns[c.id] = point(a, oCampaign)
            }

            // Edges. Control points pull each curve slightly sideways so links read as a web, not spokes.
            func control(_ p: CGPoint, _ q: CGPoint, bend: CGFloat) -> CGPoint {
                let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                let dx = q.x - p.x, dy = q.y - p.y, len = max(1, sqrt(dx * dx + dy * dy))
                return CGPoint(x: mid.x - dy / len * len * bend, y: mid.y + dx / len * len * bend)
            }
            for f in d.family {
                guard let p = family[f.id] else { continue }
                let c: Color = switch f.status { case .replied: Theme.safe; case .noReply: Theme.caution; case .waiting: Theme.accent; case .none: Theme.borderStrong }
                edges.append(Edge(id: "you-f\(f.id)", a: .you, b: .family(f.id), from: you, to: p, control: control(you, p, bend: 0.08),
                                  fromColor: Theme.accent, toColor: c, width: 2.2,
                                  dashed: f.status == .waiting || f.status == .noReply, baseOpacity: 0.85))
            }
            for t in d.threats {
                guard let p = threats[t.id] else { continue }
                let c = t.isSevere ? Theme.danger : Theme.caution
                edges.append(Edge(id: "you-t\(t.id)", a: .you, b: .threat(t.id), from: you, to: p, control: control(you, p, bend: 0.12),
                                  fromColor: Theme.accent, toColor: c, width: 1.6, dashed: false, baseOpacity: 0.55))
                if let cp = campaigns[t.campaignId] {
                    edges.append(Edge(id: "t\(t.id)-c\(t.campaignId)", a: .threat(t.id), b: .campaign(t.campaignId),
                                      from: p, to: cp, control: control(p, cp, bend: -0.18),
                                      fromColor: c, toColor: Theme.borderStrong, width: 1.4, dashed: true, baseOpacity: 0.6))
                }
            }
            // Cross-links: who was alerted about which threat. Curves swing out around the hub.
            for l in d.alertLinks {
                guard let fp = family[l.familyId], let tp = threats[l.threatId] else { continue }
                let side: CGFloat = fp.x < you.x ? -1 : 1
                let ctrl = CGPoint(x: you.x + side * oThreat.rx * 0.95, y: you.y)
                edges.append(Edge(id: "f\(l.familyId)-t\(l.threatId)", a: .family(l.familyId), b: .threat(l.threatId),
                                  from: fp, to: tp, control: ctrl,
                                  fromColor: l.answered ? Theme.safe : Theme.caution, toColor: Theme.borderStrong,
                                  width: 1.2, dashed: !l.answered, baseOpacity: 0.35))
            }
        }

        /// The selected node, its neighbours and the links between them.
        func connected(to selection: NetworkNodeID?) -> Focus {
            guard let s = selection, s != .you else { return Focus() }
            var f = Focus(nodes: [s])
            for e in edges where e.a == s || e.b == s {
                f.edgeIds.insert(e.id); f.nodes.insert(e.a); f.nodes.insert(e.b)
            }
            return f
        }
    }
}

private struct YouNode: View {
    let pulse: Bool
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.16)).frame(width: 74, height: 74)
                .scaleEffect(on ? 1.08 : 0.94)
            Circle().fill(Theme.accentFill).frame(width: 56, height: 56)
                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
        }
        .overlay(alignment: .bottom) {
            Text("You").font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 6).background(Theme.surface, in: Capsule())
                .fixedSize().offset(y: 14)
        }
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

private struct FamilyNode: View {
    let node: NetworkDashboard.FamilyNode
    let photo: Data?

    var body: some View {
        let (tone, symbol) = Self.look(node.status)
        MonogramAvatar(name: node.contact.name, size: 44, imageData: photo)
            .padding(3)
            .background(Theme.surface, in: Circle())
            .overlay(Circle().strokeBorder(tone.color, lineWidth: node.status == .none ? 1 : 2.5))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .overlay(alignment: .bottomTrailing) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.surface)
                        .frame(width: 18, height: 18)
                        .background(tone.color, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
            .overlay(alignment: .top) {
                Text(FamilyReplies.shortName(node.contact.name))
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).padding(.horizontal, 5).background(Theme.surface, in: Capsule())
                    .fixedSize().offset(y: -18)
            }
    }

    static func look(_ s: FamilyReplies.MemberStatus) -> (StatusTone, String?) {
        switch s {
        case .replied: (.success, "checkmark")
        case .waiting: (.info, "clock")
        case .noReply: (.caution, "exclamationmark")
        case .none: (.neutral, nil)
        }
    }
}

private struct ThreatNodeView: View {
    let threat: NetworkDashboard.ThreatNode
    var body: some View {
        let tone: StatusTone = threat.isSevere ? .danger : .caution
        Image(systemName: threat.kind == .call ? "phone.down.fill" : "message.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(tone.color)
            .frame(width: 32, height: 32)
            .background(tone.soft, in: Circle())
            .overlay(Circle().strokeBorder(tone.color.opacity(0.75), lineWidth: 1.5))
            .shadow(color: tone.color.opacity(0.18), radius: 4, y: 2)
    }
}

private struct CampaignNodeView: View {
    let node: NetworkDashboard.CampaignNode
    var body: some View {
        let d = 34 + 20 * node.weight
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Theme.surfaceSunken)
                // Share of this week's reports, as a ring.
                Circle().trim(from: 0, to: max(0.08, node.weight))
                    .stroke(Theme.borderStrong, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)
                Text(compact(node.campaign.weeklyReports))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            Text(node.campaign.title)
                .font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(width: 74)
                .fixedSize(horizontal: false, vertical: true)
        }
        .offset(y: 14) // keep the circle (not the label) on the orbit
    }

    private func compact(_ n: UInt32) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(n)"
    }
}

/// Shapes and icons, so the map never relies on color alone.
struct NetworkLegend: View {
    var body: some View {
        FlowLayout(spacing: Theme.Space.s) { items }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.top, Theme.Space.s)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var items: some View {
        Label("Replied", systemImage: "checkmark.circle")
        Label("Waiting", systemImage: "clock")
        Label("No reply", systemImage: "exclamationmark.circle")
        Label("Threat blocked", systemImage: "message")
        Label("Campaign (reports)", systemImage: "circle")
        Label("Alerted about", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        Text("Rings, inside out: family, threats blocked, scam campaigns")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the selected node is.
struct NetworkNodeDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let dashboard: NetworkDashboard
    let selection: NetworkNodeID?

    var body: some View {
        switch selection {
        case .family(let id):
            if let f = dashboard.family.first(where: { $0.id == id }) {
                Card {
                    HStack(spacing: Theme.Space.s) {
                        MonogramAvatar(name: f.contact.name, size: Theme.Icon.l, imageData: model.contactsBridge.photos[id])
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.contact.name).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                            Text([f.contact.relationship, PhoneNumbers.formatted(f.contact.phoneE164)].filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    MemberStatusPill(status: f.status)
                    if let url = URL(string: "tel:\(f.contact.phoneE164)") {
                        Button { openURL(url) } label: { Label("Call \(FamilyReplies.shortName(f.contact.name))", systemImage: "phone") }
                            .buttonStyle(KavachButtonStyle(.secondary))
                    }
                }
            }
        case .threat(let id):
            if let t = dashboard.threats.first(where: { $0.id == id }) {
                Card {
                    StatusPill(t.isSevere ? (t.kind == .call ? "Critical call" : "Likely scam") : "Suspicious",
                               systemImage: t.isSevere ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                               tone: t.isSevere ? .danger : .caution)
                    if t.kind == .call {
                        // The caller's number is the most useful fact: show it large and copyable.
                        Text(t.number.isEmpty ? "Number not given" : t.number)
                            .font(TypeScale.title.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .accessibilityLabel(t.number.isEmpty ? "Number not given" : "Caller \(t.number)")
                        if !t.claimedIdentity.isEmpty {
                            Text("Said they were: \(t.claimedIdentity)").font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                        }
                        Text(t.detail).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(t.title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                        if !t.excerpt.isEmpty {
                            Text("“\(t.excerpt)”").font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                                .lineLimit(4).textSelection(.enabled)
                        }
                        Text(t.detail).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                    }
                    if let c = dashboard.campaigns.first(where: { $0.id == t.campaignId }) {
                        Label("Part of “\(c.campaign.title)”", systemImage: "link").font(TypeScale.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let date = t.date {
                        Text(date, format: .relative(presentation: .named)).font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    if let incidentId = t.incidentId {
                        NavigationLink { ReportDetailView(incidentId: incidentId) } label: {
                            Label("Open full report", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(KavachButtonStyle(.secondary))
                    }
                }
            }
        case .campaign(let id):
            if let c = dashboard.campaigns.first(where: { $0.id == id }) {
                Card {
                    Label("Scam going around", systemImage: "antenna.radiowaves.left.and.right")
                        .font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                    Text(c.campaign.title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text(c.campaign.tacticSummary).font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                    Text("\(c.campaign.weeklyReports) community reports this week"
                         + (c.linkedThreats > 0 ? " · \(c.linkedThreats) blocked for you" : ""))
                        .font(TypeScale.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
        case .you, .none:
            Card {
                Text("Tap a circle to see who's in your network and what was blocked.")
                    .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                Text("\(dashboard.family.count) family member\(dashboard.family.count == 1 ? "" : "s") · \(dashboard.threats.count) threat\(dashboard.threats.count == 1 ? "" : "s") blocked · \(dashboard.campaigns.count) campaign\(dashboard.campaigns.count == 1 ? "" : "s")")
                    .font(TypeScale.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

struct MemberStatusPill: View {
    let status: FamilyReplies.MemberStatus
    var body: some View {
        switch status {
        case .replied: StatusPill("Replied last time", systemImage: "checkmark.circle.fill", tone: .success)
        case .waiting: StatusPill("Waiting for a reply", systemImage: "clock", tone: .info)
        case .noReply: StatusPill("Didn't reply last time", systemImage: "exclamationmark.circle.fill", tone: .caution)
        case .none: StatusPill("No requests yet", systemImage: "minus.circle", tone: .neutral)
        }
    }
}

/// The accessible alternative to the map (default with VoiceOver).
struct NetworkListView: View {
    @Environment(AppModel.self) private var model
    let dashboard: NetworkDashboard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    listHeader("Family", count: dashboard.family.count)
                    if dashboard.family.isEmpty {
                        emptyRow("No family members yet. Add them in Family.")
                    }
                    ForEach(dashboard.family) { f in
                        HStack(spacing: Theme.Space.s) {
                            MonogramAvatar(name: f.contact.name, size: 36, imageData: model.contactsBridge.photos[f.id])
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.contact.name).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                                if !f.contact.relationship.isEmpty {
                                    Text(f.contact.relationship).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer(minLength: Theme.Space.xs)
                            MemberStatusPill(status: f.status)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    listHeader("Blocked this week", count: dashboard.threats.count)
                    if dashboard.threats.isEmpty { emptyRow("Nothing blocked this week.") }
                    ForEach(dashboard.threats) { t in
                        let campaign = dashboard.campaigns.first { $0.id == t.campaignId }?.campaign.title
                        VStack(alignment: .leading, spacing: 2) {
                            Label(t.title, systemImage: t.kind == .call ? "phone.down" : "message")
                                .font(TypeScale.headline)
                                .foregroundStyle(t.isSevere ? Theme.danger : Theme.caution)
                            Text(t.detail).font(TypeScale.callout).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            if let campaign {
                                Text("Part of “\(campaign)”").font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    listHeader("Scams going around", count: dashboard.campaigns.count)
                    ForEach(dashboard.campaigns) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.campaign.title).font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(c.campaign.weeklyReports) reports").font(TypeScale.callout.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func listHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(count)").font(TypeScale.overline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.m).padding(.bottom, Theme.Space.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(TypeScale.body).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.m)
    }
}

// MARK: Chart

/// Checks per day, stacked by verdict. Legend words + a text summary, so color is never the only cue.
struct ChecksChart: View {
    let days: [NetworkDashboard.Day]

    var body: some View {
        Chart {
            ForEach(days) { d in
                ForEach(Verdict.allCases, id: \.self) { v in
                    if d.count(v) > 0 {
                        BarMark(x: .value("Day", d.start, unit: .day), y: .value("Messages", d.count(v)), width: .ratio(0.55))
                            .foregroundStyle(by: .value("Verdict", v.word))
                            .accessibilityLabel(d.start.formatted(.dateTime.weekday(.wide)))
                            .accessibilityValue("\(d.count(v)) \(v.word)")
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: Verdict.allCases.map(\.word),
                                   range: [Theme.safe, Theme.caution, Theme.danger])
        .chartLegend(position: .bottom, alignment: .leading, spacing: Theme.Space.s)
        .chartXAxis {
            AxisMarks(values: days.map(\.start)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel().foregroundStyle(Theme.textSecondary)
            }
        }
        .chartYScale(domain: 0...max(3, days.map(\.total).max() ?? 0))
        .chartXScale(domain: (days.first?.start ?? .now)...(days.last.map { $0.start.addingTimeInterval(86_400) } ?? .now))
        .frame(height: 200)
    }
}
