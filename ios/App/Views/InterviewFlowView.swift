import KavachKit
import SwiftUI

/// Runs the shared interview for an incident, then shows the level the module set. Each answer is
/// saved as it's given (`save_answer`), so a report left halfway resumes at `startIndex` later.
struct InterviewFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    let incidentId: UInt64
    /// First question to show. nil = resume at the first unanswered one, once the incident is loaded.
    var startIndex: Int?
    /// E.164 to `report_number` after the last answer (reported calls); "" = none.
    var reportNumber = ""
    var title = "Tell us what happened"
    @State private var finished = Self.debugFinished
    @State private var severity: Severity = .unrated

    var body: some View {
        Group {
            if finished {
                result
            } else if startIndex == nil && !model.incidents.contains(where: { $0.id == incidentId }) {
                // Opened before the first poll (cold launch from a notification): wait for the answers
                // so we resume at the right question.
                ProgressView("Opening your report…").tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .kavachScreenBackground()
                    .task { await model.refresh() }
            } else {
                InterviewView(title: title, startIndex: startIndex ?? model.interviewStart(for: incidentId), save: { qid, answer in
                    guard let api = model.api else { throw KavachError.notRegistered }
                    try await api.saveAnswer(incidentId: incidentId, questionId: qid, answer: answer)
                }, onDone: {
                    finished = true
                    Task {
                        await fileNumber()
                        await loadSeverity()
                    }
                })
            }
        }
    }

    private var result: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SeverityBadge(severity)
                    Text(headline).font(TypeScale.display)
                        .foregroundStyle(severity == .critical ? Theme.danger : Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail).font(.title3).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !reportNumber.isEmpty {
                    StatusBanner(tone: .info, systemImage: "checkmark.seal",
                                 title: "Number reported",
                                 message: "\(PhoneNumbers.formatted(reportNumber)) is now on your report. Enough reports warn everyone who uses \(model.config.displayName).")
                }
                if let r = model.alertRequest(for: incidentId) {
                    FamilyReplyBanner(request: r)
                } else if severity >= .high {
                    if model.contacts.contains(where: { $0.consentStatus == "accepted" }) {
                        StatusBanner(tone: .info, systemImage: "paperplane", title: "Telling your family…",
                                     message: "We'll show here when they reply.")
                    } else {
                        StatusBanner(tone: .caution, systemImage: "person.2.slash", title: "No family to tell yet",
                                     message: "Add a family member in the Family tab so someone can help next time.")
                    }
                }
                let steps = model.steps(for: incidentId)
                if !steps.isEmpty {
                    Card {
                        Text("Your first steps").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(steps.prefix(3).enumerated()), id: \.element.id) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text("\(i + 1).").font(TypeScale.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                Text(RecoveryLibrary.shared.text(for: step.stepKey)).font(TypeScale.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if steps.count > 3 {
                            Text("and \(steps.count - 3) more").font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                VStack(spacing: Theme.Space.s) {
                    if !model.steps(for: incidentId).isEmpty {
                        NavigationLink {
                            ActNowView(incidentId: incidentId)
                        } label: {
                            Label("Show me what to do", systemImage: "list.number")
                        }
                        .buttonStyle(KavachButtonStyle(severity == .critical ? .destructive : .primary))
                    }
                    RepeatSpeechButton()
                    Button("Done") { model.route = nil }
                        .buttonStyle(KavachButtonStyle(model.steps(for: incidentId).isEmpty ? .primary : .secondary))
                }
            }
            .padding(Theme.Space.m)
        }
        .kavachScreenBackground()
        .navigationTitle("Thank you")
        #if DEBUG
        .task { if ProcessInfo.processInfo.environment["KAVACH_DEBUG_RESULT"] == "1" { await loadSeverity() } }
        #endif
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
    }

    private var headline: String {
        switch severity {
        case .critical: "Act now"
        case .high: "Be careful"
        case .medium: "Good job not sharing"
        case .low: "You did the right thing"
        case .unrated: "Your answers are saved"
        }
    }

    private var detail: String {
        switch severity {
        case .critical: "This is serious, but you can fix a lot of it right now. Your family is being told."
        case .high: "Some of what you shared could be misused. Follow the steps, and your family will hear from us."
        case .medium: "This looks like a scam. You didn't share anything, which is exactly right."
        case .low: "Nothing was shared. We'll count this in your weekly summary."
        case .unrated: "We're still looking at this. Check back in a moment."
        }
    }

    /// Adds the person's vote for the caller's number (idempotent per person; feeds caller labels).
    private func fileNumber() async {
        guard !reportNumber.isEmpty, let api = model.api else { return }
        do {
            try await ReportFiling.finish(personId: model.personId, callerE164: reportNumber, backend: api)
        } catch {
            model.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The module sets severity in the same transaction as the answer; poll briefly for steps.
    private func loadSeverity() async {
        for _ in 0..<6 {
            await model.refresh()
            if let inc = model.incidents.first(where: { $0.id == incidentId }) {
                severity = inc.severityLevel
                if severity < .high || !model.steps(for: incidentId).isEmpty { break }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if prefs.autoSpeak { Speaker.shared.speak("\(headline). \(detail)") }
    }
}

extension InterviewFlowView {
    /// DEBUG (screenshots): `KAVACH_DEBUG_RESULT=1` opens straight on the result.
    static var debugFinished: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["KAVACH_DEBUG_RESULT"] == "1"
        #else
        false
        #endif
    }
}
