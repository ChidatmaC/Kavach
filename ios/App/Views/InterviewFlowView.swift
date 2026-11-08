import KavachKit
import SwiftUI

/// Runs the shared interview for an incident, then shows the level the module set.
struct InterviewFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    let incidentId: UInt64
    @State private var finished = false
    @State private var severity: Severity = .unrated

    var body: some View {
        Group {
            if finished {
                result
            } else {
                InterviewView(save: { qid, answer in
                    guard let api = model.api else { throw KavachError.notRegistered }
                    try await api.saveAnswer(incidentId: incidentId, questionId: qid, answer: answer)
                }, onDone: {
                    finished = true
                    Task { await loadSeverity() }
                })
            }
        }
    }

    private var result: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SeverityBadge(severity)
                Text(headline).font(.largeTitle.weight(.bold))
                    .foregroundStyle(severity == .critical ? Theme.danger : .primary)
                    .accessibilityAddTraits(.isHeader)
                Text(detail).font(.title3)
                if !model.steps(for: incidentId).isEmpty {
                    NavigationLink {
                        ActNowView(incidentId: incidentId)
                    } label: {
                        Label("Show me what to do", systemImage: "list.number")
                    }
                    .buttonStyle(KavachButtonStyle(prominent: true, tint: severity == .critical ? Theme.danger : Theme.accent))
                }
                RepeatSpeechButton()
                Button("Done") { model.route = nil }
                    .buttonStyle(KavachButtonStyle())
            }
            .padding()
        }
        .navigationTitle("Thank you")
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
