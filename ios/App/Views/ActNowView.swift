import KavachKit
import SwiftUI

/// Act now: red header (Critical only), numbered checklist from `my_recovery_steps` worded from the
/// bundled vetted library (D10), whether the family saw it, Call my family, reassurance line.
struct ActNowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.openURL) private var openURL
    let incidentId: UInt64
    @State private var spoke = false

    private var incident: Incident? { model.incidents.first { $0.id == incidentId } }
    private var steps: [RecoveryStep] { model.steps(for: incidentId) }
    private var critical: Bool { incident?.severityLevel == .critical }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header

                if let r = model.alertRequest(for: incidentId) {
                    FamilyReplyBanner(request: r)
                }

                if steps.isEmpty {
                    ProgressView("Getting your steps…").tint(Theme.accent)
                } else {
                    let done = steps.filter(\.done).count
                    HStack {
                        Text("Your steps").font(TypeScale.title).foregroundStyle(Theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(done) of \(steps.count) done").font(TypeScale.callout.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    VStack(spacing: Theme.Space.s) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                            StepRow(number: i + 1, step: step)
                        }
                    }
                }

                RepeatSpeechButton()

                if let c = callTarget, let url = URL(string: "tel:\(c.phoneE164)") {
                    Button { openURL(url) } label: { Label("Call \(FamilyReplies.shortName(c.name))", systemImage: "phone.fill") }
                        .buttonStyle(KavachButtonStyle(.primary))
                        .accessibilityLabel("Call my family: \(c.name)")
                }
                Text("You're not alone. Scammers target lots of careful people, and acting quickly really helps.")
                    .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.m)
        }
        .debugScrollAnchor()
        .kavachScreenBackground()
        .navigationTitle(critical ? "Act now" : "Next steps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if case .actNow = model.route { Button("Close") { model.route = nil } }
            }
        }
        .onChange(of: steps.count, initial: true) { _, count in
            guard prefs.autoSpeak, !spoke, count > 0 else { return }
            spoke = true
            Speaker.shared.speak(spokenSteps)
        }
    }

    /// Red only for Critical; High gets the caution color.
    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.title.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(critical ? "Act now" : "Be careful").font(TypeScale.display)
                Text("Do these one at a time. Tick each one when it's done.").font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(critical ? Theme.onDanger : Theme.caution)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(critical ? Theme.danger : Theme.cautionSoft,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay {
            if !critical {
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.caution.opacity(0.4), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The family member asked about this incident, else the emergency contact.
    private var callTarget: Contact? {
        if let r = model.alertRequest(for: incidentId), let c = FamilyReplies.callTarget(for: r, in: model.contacts) { return c }
        return model.emergencyContact
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
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(step.done ? Theme.textSecondary : Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(step.done ? Theme.surfaceSunken : Theme.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(step.priorityLabel).font(TypeScale.overline)
                        .foregroundStyle(step.priority == "now" && !step.done ? Theme.caution : Theme.textSecondary)
                    Text(RecoveryLibrary.shared.text(for: step.stepKey))
                        .font(TypeScale.body.weight(.medium))
                        .foregroundStyle(step.done ? Theme.textSecondary : Theme.textPrimary)
                        .strikethrough(step.done)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if busy { ProgressView() } else {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(step.done ? Theme.safe : Theme.borderStrong)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Space.m)
            .frame(minHeight: 64)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(prefs.highContrast ? Theme.borderStrong : Theme.separator, lineWidth: prefs.highContrast ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.success, trigger: taps) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityLabel("Step \(number), \(step.priorityLabel): \(RecoveryLibrary.shared.text(for: step.stepKey))")
        .accessibilityValue(step.done ? "Done" : "Not done")
        .accessibilityHint(step.done ? "Double tap to mark not done" : "Double tap to mark done")
    }
}

/// "I need help": steps if something is open, otherwise start the interview or call family.
struct NeedHelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var incident: Incident?
    @State private var starting = false
    @State private var goInterview = false
    @State private var goReport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("We'll help you take the next step. Choose what fits.")
                    .font(.title3).foregroundStyle(Theme.textPrimary)

                if let active = model.activeIncident {
                    option(icon: "list.number", title: "Open my steps", detail: "Continue the checklist you started.",
                           tone: active.severityLevel == .critical ? .danger : .caution) {
                        model.route = .actNow(incidentId: active.id)
                    }
                }
                option(icon: "questionmark.bubble", title: "Something happened",
                       detail: "Answer 5 short questions and we'll tell you what to do.", tone: .info, busy: starting) {
                    Task {
                        starting = true
                        incident = await model.openIncident(entryPoint: "app")
                        starting = false
                        goInterview = incident != nil
                    }
                }
                option(icon: "flag", title: "Report a call",
                       detail: "A call felt wrong. Tell us the number and what happened.", tone: .info) {
                    goReport = true
                }
                option(icon: "phone", title: "I'm on a call right now",
                       detail: "Open Call Companion and tell your family.", tone: .info) {
                    model.route = .companion
                }
                if let c = model.emergencyContact, let url = URL(string: "tel:\(c.phoneE164)") {
                    option(icon: "person.wave.2", title: "Call \(FamilyReplies.shortName(c.name))",
                           detail: [c.relationship, PhoneNumbers.formatted(c.phoneE164)].filter { !$0.isEmpty }.joined(separator: " · "),
                           tone: .success) { openURL(url) }
                        .accessibilityLabel("Call my family: \(c.name)")
                }
                if let e = model.lastError {
                    StatusBanner(tone: .caution, systemImage: "exclamationmark.triangle", title: e)
                }
            }
            .padding(Theme.Space.m)
        }
        .kavachScreenBackground()
        .navigationTitle("I need help")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .navigationDestination(isPresented: $goInterview) {
            if let incident { InterviewFlowView(incidentId: incident.id) }
        }
        .navigationDestination(isPresented: $goReport) { ReportCallView() }
    }

    private func option(icon: String, title: String, detail: String, tone: StatusTone, busy: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                IconTile(icon, tone: tone, size: Theme.Icon.l)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if busy { ProgressView() } else {
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
    }
}
