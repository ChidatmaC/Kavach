import KavachKit
import SwiftUI

/// Act now: red header (Critical only), numbered checklist from `my_recovery_steps` worded from the
/// bundled vetted library (D10), Call my family, reassurance line.
struct ActNowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.openURL) private var openURL
    let incidentId: UInt64
    @State private var spoke = false

    private var incident: Incident? { model.incidents.first { $0.id == incidentId } }
    private var steps: [RecoveryStep] { model.steps(for: incidentId) }
    private var critical: Bool { incident?.severityLevel == .critical }
    private var headerColor: Color { critical ? Theme.danger : Theme.amber }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(critical ? "Act now" : "Be careful", systemImage: "exclamationmark.shield.fill")
                        .font(.largeTitle.weight(.heavy))
                    Text("Do these one at a time. Tick each one when it's done.").font(.title3)
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(headerColor, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if steps.isEmpty {
                    ProgressView("Getting your steps…")
                }
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    StepRow(number: i + 1, step: step)
                }

                RepeatSpeechButton()

                if let c = model.emergencyContact, let url = URL(string: "tel:\(c.phoneE164)") {
                    Button { openURL(url) } label: { Label("Call \(c.name)", systemImage: "phone.fill") }
                        .buttonStyle(KavachButtonStyle(prominent: true))
                        .accessibilityLabel("Call my family: \(c.name)")
                }
                Text("You're not alone. Scammers target lots of careful people, and acting quickly really helps.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Act now")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: steps.count, initial: true) { _, count in
            guard prefs.autoSpeak, !spoke, count > 0 else { return }
            spoke = true
            Speaker.shared.speak(spokenSteps)
        }
    }

    private var spokenSteps: String {
        let lib = RecoveryLibrary.shared
        let lines = steps.filter { !$0.done }.enumerated().map { "Step \($0.offset + 1). \(lib.text(for: $0.element.stepKey))" }
        return ([critical ? "Act now." : "Be careful."] + lines).joined(separator: " ")
    }
}

struct StepRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    let number: Int
    let step: RecoveryStep
    @State private var busy = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            Task {
                busy = true
                _ = await model.run { try await $0.markStepDone(stepId: step.id, done: !step.done) }
                busy = false
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("\(number)")
                    .font(.title2.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.priorityLabel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(RecoveryLibrary.shared.text(for: step.stepKey))
                        .font(.title3)
                        .strikethrough(step.done)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if busy { ProgressView() } else {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .font(.title).foregroundStyle(step.done ? Theme.safe : .secondary)
                }
            }
            .padding(14)
            .frame(minHeight: 64)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: taps) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityLabel("Step \(number), \(step.priorityLabel): \(RecoveryLibrary.shared.text(for: step.stepKey))")
        .accessibilityValue(step.done ? "Done" : "Not done")
        .accessibilityHint(step.done ? "Double tap to mark not done" : "Double tap to mark done")
    }
}

/// "I need help": steps if something is open, otherwise start the interview, call family, or the hotline.
struct NeedHelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var incident: Incident?
    @State private var starting = false
    @State private var goInterview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("We'll help you take the next step.").font(.title2.weight(.semibold))
                if let active = model.activeIncident {
                    NavigationLink { ActNowView(incidentId: active.id) } label: {
                        Label("Open my steps", systemImage: "list.number")
                    }
                    .buttonStyle(KavachButtonStyle(prominent: true, tint: Theme.color(for: active.severityLevel)))
                }
                Button {
                    Task {
                        starting = true
                        incident = await model.openIncident(entryPoint: "app")
                        starting = false
                        goInterview = incident != nil
                    }
                } label: {
                    if starting { ProgressView() } else { Label("Something happened: answer 5 questions", systemImage: "questionmark.bubble.fill") }
                }
                .buttonStyle(KavachButtonStyle(prominent: model.activeIncident == nil))

                Button { model.route = .companion } label: { Label("I'm on a call right now", systemImage: "phone.fill") }
                    .buttonStyle(KavachButtonStyle())

                if let c = model.emergencyContact, let url = URL(string: "tel:\(c.phoneE164)") {
                    Button { openURL(url) } label: { Label("Call \(c.name)", systemImage: "person.fill") }
                        .buttonStyle(KavachButtonStyle())
                        .accessibilityLabel("Call my family: \(c.name)")
                }
                if !model.config.hotlineNumber.isEmpty, let url = URL(string: "tel:\(model.config.hotlineNumber)") {
                    Button { openURL(url) } label: { Label("Call the \(model.config.displayName) hotline", systemImage: "phone.bubble.fill") }
                        .buttonStyle(KavachButtonStyle())
                }
                if let e = model.lastError { Text(e).foregroundStyle(Theme.amber) }
            }
            .padding()
        }
        .navigationTitle("I need help")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .navigationDestination(isPresented: $goInterview) {
            if let incident { InterviewFlowView(incidentId: incident.id) }
        }
    }
}
