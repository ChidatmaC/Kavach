import KavachKit
import SwiftUI

// MARK: Your reports

/// One report: caller, where it came from, when, level and status. Unfinished reports offer
/// "Finish report" (resumes at the first unanswered question); finished ones open the summary.
struct ReportRow: View {
    @Environment(AppModel.self) private var model
    let report: ReportSummary

    var body: some View {
        Card {
            if report.isUnfinished {
                content
                Button { model.route = .interview(incidentId: report.id) } label: {
                    Label("Finish report", systemImage: "arrow.right.circle")
                }
                .buttonStyle(KavachButtonStyle(.primary))
                .accessibilityHint(resumeHint)
            } else {
                NavigationLink { ReportDetailView(incidentId: report.id) } label: {
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        content
                        Image(systemName: "chevron.right").font(.headline).foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(report.accessibilityText)
                .accessibilityHint("Shows your answers and next steps")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private var resumeHint: String {
        let q = (report.resumeIndex ?? 0) + 1
        return "Continues at question \(q) of \(InterviewScript.questions.count)"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                IconTile(report.source.symbol, tone: .info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.callerText)
                        .font(TypeScale.headline.monospacedDigit())
                        .foregroundStyle(report.hasCaller ? Theme.textPrimary : Theme.textSecondary)
                    Text(subtitle).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            // One line when it fits; otherwise stacked (FlowLayout under-measured two wrapped pills here).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.xs) { SeverityBadge(report.severity); statusPill }
                VStack(alignment: .leading, spacing: Theme.Space.xs) { SeverityBadge(report.severity); statusPill }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: report.isUnfinished ? .combine : .ignore)
        .accessibilityLabel(report.accessibilityText)
    }

    private var subtitle: String {
        var parts = [report.source.label]
        if let d = report.date { parts.append(d.formatted(.dateTime.month(.abbreviated).day().hour().minute())) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusPill: some View {
        switch report.status {
        case .unfinished: StatusPill("Not finished", systemImage: "exclamationmark.circle", tone: .caution)
        case .open: StatusPill("Answered", systemImage: "checkmark", tone: .info)
        case .resolved: StatusPill("Done", systemImage: "checkmark.circle.fill", tone: .success)
        }
    }
}

/// Network's top section: the latest reports, "See all", and Report a call.
struct ReportsSection: View {
    @Environment(AppModel.self) private var model
    /// Rows shown per group on the dashboard; "See all" shows everything.
    var perGroup = 2

    var body: some View {
        let reports = model.reports
        let sections = ReportSection.make(reports)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Your reports", detail: reports.isEmpty ? nil : "Calls and texts you told us about")
                if sections.contains(where: { $0.reports.count > perGroup }) {
                    NavigationLink("See all \(reports.count)") { ReportsListView() }
                        .font(TypeScale.headline)
                        .frame(minHeight: Theme.minTarget)
                }
            }
            if reports.isEmpty {
                Card {
                    Text("No reports yet. If a call felt wrong, report it. It takes 2 minutes and helps warn others.")
                        .font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                }
            } else {
                ForEach(sections) { section in
                    ReportGroup(section: section, limit: perGroup)
                }
            }
            ReportCallButton()
        }
    }
}

/// One status group with its subheading ("Needs your answers · 2") and rows.
struct ReportGroup: View {
    let section: ReportSection
    var limit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ReportGroupHeader(section: section)
            ForEach(limit.map { Array(section.reports.prefix($0)) } ?? section.reports) { ReportRow(report: $0) }
            if let limit, section.reports.count > limit {
                Text("\(section.reports.count - limit) more in See all")
                    .font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, Theme.Space.xs)
    }
}

struct ReportGroupHeader: View {
    let section: ReportSection

    var body: some View {
        let tone: StatusTone = switch section.kind { case .needsAnswers: .caution; case .answered: .info; case .done: .success }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: section.symbol).foregroundStyle(tone.color).accessibilityHidden(true)
                Text(section.title).font(TypeScale.overline).foregroundStyle(Theme.textPrimary)
                Text("\(section.reports.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(tone.color)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(tone.soft, in: Capsule())
                Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, Theme.Space.xxs)
                    .accessibilityHidden(true)
            }
            Text(section.detail).font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title), \(section.reports.count) \(section.reports.count == 1 ? "report" : "reports"). \(section.detail)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// "See all": every report, grouped under the same subheadings, newest first in each.
struct ReportsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ReportCallButton()
                ForEach(ReportSection.make(model.reports)) { ReportGroup(section: $0) }
            }
            .padding(Theme.Space.m)
        }
        .kavachScreenBackground()
        .navigationTitle("Your reports")
        .refreshable { await model.refresh() }
    }
}

/// A finished report: answers, steps and family replies.
struct ReportDetailView: View {
    @Environment(AppModel.self) private var model
    let incidentId: UInt64

    var body: some View {
        ScrollView {
            if let inc = model.incidents.first(where: { $0.id == incidentId }) {
                let report = ReportSummary(inc)
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(report.callerText).font(TypeScale.display.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .minimumScaleFactor(0.7).lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        Text([report.source.label,
                              report.date.map { $0.formatted(date: .abbreviated, time: .shortened) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                        SeverityBadge(report.severity)
                    }

                    if report.isUnfinished {
                        Button("Finish report") { model.route = .interview(incidentId: incidentId) }
                            .buttonStyle(KavachButtonStyle(.primary))
                    }

                    if let r = model.alertRequest(for: incidentId) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionTitle("Your family")
                            FamilyReplyBanner(request: r)
                        }
                    }

                    let lines = ReportsList.answerLines(inc.answers)
                    if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionTitle("Your answers")
                            Card {
                                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.title).font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                                        Text(line.answer).font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .accessibilityElement(children: .combine)
                                    if i < lines.count - 1 { Divider().overlay(Theme.separator) }
                                }
                            }
                        }
                    }

                    let steps = model.steps(for: incidentId)
                    if !steps.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionTitle("Your steps", detail: "\(steps.filter(\.done).count) of \(steps.count) done")
                            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                                StepRow(number: i + 1, step: step)
                            }
                        }
                    }
                }
                .padding(Theme.Space.m)
            } else {
                ProgressView().padding(Theme.Space.xl)
            }
        }
        .kavachScreenBackground()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Report a call entry points

/// "Report a call" below Home's three actions (and on Network). Accessibility Mode: a full-width
/// button, since following up on a scam call is safety-critical.
struct ReportCallButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        if prefs.accessibilityMode {
            Button { model.route = .reportCall } label: {
                Label("Report a call", systemImage: "flag")
            }
            .buttonStyle(KavachButtonStyle(.secondary))
            .accessibilityHint("Tell us about a call that felt wrong")
        } else {
            Button { model.route = .reportCall } label: {
                HStack(spacing: Theme.Space.s) {
                    IconTile("flag", tone: .info)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Report a call").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                        Text("A call felt wrong? Tell us in 2 minutes.").font(TypeScale.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(prefs.highContrast ? Theme.borderStrong : Theme.separator,
                                  lineWidth: prefs.highContrast ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Report a call")
            .accessibilityHint("Tell us about a call that felt wrong")
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Home: an incoming call just ended ("Was that a scam call?").
struct CallFollowUpCard: View {
    var body: some View {
        StatusBanner(tone: .info, systemImage: "phone.arrow.down.left",
                     title: CallFollowUpCopy.title, message: CallFollowUpCopy.body) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { buttons }
                VStack(spacing: Theme.Space.s) { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(CallFollowUpCopy.reportLabel) { CallFollowUpCenter.shared.report() }
            .buttonStyle(KavachButtonStyle(.primary))
        Button(CallFollowUpCopy.fineLabel) { CallFollowUpCenter.shared.dismiss() }
            .buttonStyle(KavachButtonStyle(.secondary))
    }
}

/// Home: the newest report whose questions aren't finished (compact: one line of text and a button).
struct UnfinishedReportBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    let report: ReportSummary
    let others: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { label; button.fixedSize() }
            VStack(alignment: .leading, spacing: Theme.Space.s) { label; button }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cautionSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(prefs.highContrast ? Theme.caution : Theme.caution.opacity(0.35), lineWidth: prefs.highContrast ? 2 : 1)
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: "list.bullet.clipboard").font(.headline).foregroundStyle(Theme.caution)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(others > 0 ? "\(others + 1) unfinished reports" : "Unfinished report")
                    .font(TypeScale.headline).foregroundStyle(Theme.caution)
                Text(detail).font(TypeScale.callout).foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var button: some View {
        Button("Finish report") { model.route = .interview(incidentId: report.id) }
            .buttonStyle(KavachButtonStyle(.primary))
            .accessibilityHint("Continues where you left off")
    }

    private var detail: String {
        let left = InterviewScript.questions.count - (report.resumeIndex ?? 0)
        let questions = "\(left) question\(left == 1 ? "" : "s") left"
        return report.hasCaller ? "\(questions) · \(report.callerText)" : questions
    }
}

/// Home: notifications are off, so we can't ask about calls right after they end.
struct NotificationsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        StatusBanner(tone: .info, systemImage: "bell.badge",
                     title: "Turn on notifications",
                     message: "So we can ask about a call right after it ends, and tell you when your family replies.") {
            if model.notificationStatus == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .buttonStyle(KavachButtonStyle(.secondary))
            } else {
                Button("Turn on notifications") { PushRegistrar.shared.requestAuthorization() }
                    .buttonStyle(KavachButtonStyle(.secondary))
            }
        }
    }
}
