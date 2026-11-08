import KavachKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if !prefs.homeShowsOnlyActions {
                    StatusCard()
                }
                // Family replies: urgent ("call them") above the actions, calm ones below. Accessibility
                // Mode keeps Home to the three actions, except an urgent "call them" warning.
                let urgent = model.relevantAlertRequests.filter(\.isUrgent)
                ForEach(urgent.prefix(2)) { r in FamilyReplyBanner(request: r) }
                ForEach(model.pendingVerifications) { v in PendingVerificationCard(verification: v) }
                // Follow-through after a call (also in Accessibility Mode: safety-critical).
                if model.callFollowUpPending { CallFollowUpCard() }
                let unfinished = model.unfinishedReports
                if let first = unfinished.first, !model.callFollowUpPending {
                    UnfinishedReportBanner(report: first, others: unfinished.count - 1)
                }

                VStack(spacing: Theme.Space.s) {
                    BigActionButton("Check a message", systemImage: "text.magnifyingglass",
                                    subtitle: "Paste a text or choose a screenshot", primary: true) {
                        model.route = .check(prefill: nil)
                    }
                    BigActionButton("I'm on a call", systemImage: "phone",
                                    subtitle: "Open Call Companion and tell your family") { model.route = .companion }
                    BigActionButton("I need help", systemImage: "lifepreserver",
                                    subtitle: "Something happened, or I shared something") { model.route = .needHelp }
                }
                ReportCallButton()
                if model.showsNotificationCard { NotificationsCard() }

                if !prefs.homeShowsOnlyActions {
                    let calm = model.relevantAlertRequests.filter { !$0.isUrgent }
                    if !calm.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionTitle("Your family")
                            ForEach(calm.prefix(2)) { r in FamilyReplyBanner(request: r) }
                        }
                    }
                }

                if !prefs.homeShowsOnlyActions && model.agentContactPrompt != .saved && !model.agentNumber.isEmpty {
                    AgentContactHomeCard()
                }
                if !prefs.homeShowsOnlyActions {
                    ThisWeekSection()
                }
                if let problem = model.connectionProblem {
                    Label(problem, systemImage: "wifi.exclamationmark")
                        .font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Connection problem: \(problem)")
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.animation(Theme.Motion.emphasized, reduceMotion: reduceMotion), value: model.relevantAlertRequests)
            .animation(Theme.Motion.animation(Theme.Motion.emphasized, reduceMotion: reduceMotion), value: model.callFollowUpPending)
        }
        .debugScrollAnchor()
        .kavachScreenBackground()
        .navigationTitle(model.person.map { "Hi, \($0.displayName)" } ?? model.config.displayName)
        .refreshable { await model.refresh() }
    }
}

/// Protection status: "You're protected" or the open incident that needs attention.
struct StatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            if let active = model.activeIncident {
                let sev = active.severityLevel
                let critical = sev == .critical
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    IconTile(critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                             tone: critical ? .danger : .caution)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(critical ? "Act now" : "Please follow up")
                            .font(TypeScale.title).foregroundStyle(Theme.color(for: sev))
                        let left = model.steps(for: active.id).filter { !$0.done }.count
                        Text("\(left) step\(left == 1 ? "" : "s") left to stay safe.")
                            .font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                    }
                }
                Button("See my steps") { model.route = .actNow(incidentId: active.id) }
                    .buttonStyle(KavachButtonStyle(critical ? .destructive : .primary))
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    IconTile("checkmark.shield.fill", tone: .success)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("You're protected").font(TypeScale.title).foregroundStyle(Theme.textPrimary)
                        let n = model.scamsStoppedThisWeek
                        Text(n == 0 ? "No scams got through this week." : "\(n) scam\(n == 1 ? "" : "s") stopped this week.")
                            .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Divider().overlay(Theme.separator)
            HStack(spacing: Theme.Space.m) {
                let paused = model.person?.sharingPaused == true
                let look = SettingToggle.sharingPaused.appearance(isOn: paused)
                Label(look.status, systemImage: look.systemImage)
                    .foregroundStyle(paused ? Theme.caution : Theme.textSecondary)
                    .accessibilityLabel(paused ? "\(look.status). Turn them back on in Family." : look.status)
                Spacer(minLength: 0)
                let n = model.contacts.count
                Label("\(n) in your family", systemImage: "person.2")
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(TypeScale.callout.weight(.medium))
        }
        .accessibilityElement(children: .contain)
    }
}

/// One family reply request on Home: waiting (calm), reminded/unanswered (call button), or seen.
struct FamilyReplyBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let request: AlertRequest

    var body: some View {
        let headline = FamilyReplies.headline(request, contacts: model.contacts)
        let detail = FamilyReplies.detail(request)
        switch request.phase {
        case .waiting:
            StatusBanner(tone: .info, systemImage: "clock", title: headline, message: detail)
        case .acknowledged:
            StatusBanner(tone: .success, systemImage: "checkmark.circle.fill", title: headline, message: detail)
        case .reminded, .unanswered:
            StatusBanner(tone: .caution, systemImage: "phone.badge.waveform", title: headline, message: detail) {
                if let c = FamilyReplies.callTarget(for: request, in: model.contacts),
                   let url = URL(string: "tel:\(c.phoneE164)") {
                    Button { openURL(url) } label: {
                        Label("Call \(FamilyReplies.shortName(c.name))", systemImage: "phone.fill")
                    }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .accessibilityHint("Calls \(c.name) at \(PhoneNumbers.formatted(c.phoneE164))")
                }
            }
        }
    }
}

/// Home's "This week": recent checks, the latest briefing and scams going around.
struct ThisWeekSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = Array(model.checks.prefix(3))
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionTitle("This week")
            if let b = model.briefings.first {
                BriefingCard(briefing: b, compact: true)
            }
            if !recent.isEmpty {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { i, c in
                            CheckRow(check: c)
                            if i < recent.count - 1 { Divider().overlay(Theme.separator).padding(.leading, Theme.Space.m) }
                        }
                    }
                }
            }
            if let top = model.campaigns.first {
                Card {
                    Label("Going around", systemImage: "antenna.radiowaves.left.and.right")
                        .font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                    Text(top.title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text(top.tacticSummary).font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                    Text("\(top.weeklyReports) reports this week").font(TypeScale.footnote.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if recent.isEmpty && model.briefings.isEmpty && model.campaigns.isEmpty {
                Text("Checks and your weekly summary will show up here.")
                    .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// A checked message in a list: verdict, reason, when.
struct CheckRow: View {
    let check: MessageCheck
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                VerdictBadge(check.verdictKind, large: false)
                Spacer()
                if let d = check.createdAt.date {
                    Text(d, format: .relative(presentation: .named)).font(TypeScale.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(check.reason.isEmpty ? check.contentRedacted : check.reason)
                .font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Weekly briefing with Read aloud; "Get my briefing now" when there is none yet.
struct BriefingCard: View {
    @Environment(AppModel.self) private var model
    let briefing: Briefing?
    var compact = false
    @State private var requested = false

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Weekly briefing", systemImage: "newspaper")
                    .font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                Spacer()
                if let d = briefing?.createdAt.date {
                    Text(d, format: .dateTime.weekday(.wide).month().day()).font(TypeScale.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let b = briefing {
                Text(b.summaryText).font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 4 : nil)
                Button {
                    Speaker.shared.speak(b.spokenText.isEmpty ? b.summaryText : b.spokenText)
                } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
                    .buttonStyle(KavachButtonStyle(.quiet))
                    .padding(.horizontal, -Theme.Space.m)
            } else {
                Text(requested ? "Your briefing is on its way. It will show here and arrive by text."
                               : "A short summary of your week arrives Sunday evening.")
                    .font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                if !requested {
                    Button("Get my briefing now") {
                        Task { requested = await model.run { try await $0.requestBriefing(personId: model.personId) } }
                    }
                    .buttonStyle(KavachButtonStyle(.secondary))
                }
            }
        }
    }
}

/// Trusted Sender Check on the relative's phone (also delivered by push).
struct PendingVerificationCard: View {
    @Environment(AppModel.self) private var model
    let verification: Verification
    @State private var busy = false

    var body: some View {
        StatusBanner(tone: .info, systemImage: "person.badge.shield.checkmark",
                     title: "Did you send this?",
                     message: "Someone asked a family member for something using your name.") {
            HStack(spacing: Theme.Space.s) {
                Button("Yes, it was me") { answer(true) }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .accessibilityHint("Needs Face ID or your passcode")
                Button("No, not me") { answer(false) }
                    .buttonStyle(KavachButtonStyle(.secondary))
            }
            .disabled(busy)
        }
    }

    private func answer(_ yes: Bool) {
        Task {
            busy = true
            await PushRegistrar.answerTrustedSender(verificationId: verification.id, confirmed: yes)
            busy = false
        }
    }
}
