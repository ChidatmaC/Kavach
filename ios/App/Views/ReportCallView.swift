import KavachKit
import SwiftUI

/// Report a call, step 1 of 2: the caller's number (iOS never tells apps who called). Shows what the
/// community knows about the number, then opens the incident (`open_incident`, entry `report_swipe`,
/// deterministic request key) so it exists even if the person stops halfway, and runs the shared
/// interview (step 2: "Did you answer the call?", then the 5 questions if they did), saving each answer
/// as it goes. The last answer (or "No, I missed it") files the number (`report_number`) and shows the
/// module's result.
struct ReportCallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raw = ""
    @State private var startedAt = Date()
    @State private var incident: Incident?
    @State private var starting = false
    @State private var goInterview = false
    @FocusState private var numberFocused: Bool

    private var e164: String? { PhoneNumbers.e164(raw) }
    private var reputation: CallerReputation? {
        e164.flatMap { CallerReputation(e164: $0, labels: model.callerLabels) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Step 1 of 2").font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                    Text("What number called you?")
                        .font(.title.weight(.bold)).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Copy it from Phone, Recents: tap the ⓘ next to the call, then touch and hold the number.")
                        .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                numberField

                if let e164 {
                    reputationBanner(e164)
                } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("That number doesn't look complete. Use 10 digits, or start with +.",
                          systemImage: "exclamationmark.triangle")
                        .font(TypeScale.callout).foregroundStyle(Theme.caution)
                }

                VStack(spacing: Theme.Space.s) {
                    Button { start(callerE164: e164 ?? "") } label: {
                        if starting { ProgressView().tint(Theme.onAccent) } else { Text("Continue") }
                    }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .disabled(e164 == nil || starting)
                    .accessibilityHint("Then tell us if you answered, and a few short questions")

                    Button("I don't know the number") { start(callerE164: "") }
                        .buttonStyle(KavachButtonStyle(.secondary))
                        .disabled(starting)
                        .accessibilityHint("Report the call without a number")
                }

                if let e = model.lastError, !starting {
                    StatusBanner(tone: .caution, systemImage: "wifi.exclamationmark", title: "Couldn't start the report",
                                 message: e)
                }
            }
            .padding(Theme.Space.m)
            .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: e164)
        }
        .scrollDismissesKeyboard(.interactively)
        .kavachScreenBackground()
        .navigationTitle("Report a call")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { if model.route == .reportCall { model.route = nil } else { dismiss() } }
            }
        }
        .navigationDestination(isPresented: $goInterview) {
            if let incident {
                InterviewFlowView(incidentId: incident.id,
                                  reportNumber: incident.callerE164, title: "Report a call")
            }
        }
        .task {
            CallFollowUpCenter.shared.dismissPromptOnly()
            #if DEBUG
            if raw.isEmpty, let n = model.debugReportNumber { raw = n }
            #endif
            if model.callerLabels.isEmpty { await model.refreshLabelsAndCampaigns() }
        }
    }

    private var numberField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Phone number", text: $raw)
                .font(.title2.monospacedDigit())
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($numberFocused)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: 56)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(numberFocused ? Theme.accent : Theme.borderStrong, lineWidth: numberFocused ? 2 : 1))
                .accessibilityLabel("Caller's phone number")
            HStack(spacing: Theme.Space.s) {
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { raw = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.m))
                .controlSize(.large)
                .tint(Theme.accentFill)
                if !raw.isEmpty {
                    Button { raw = "" } label: { Label("Clear", systemImage: "xmark.circle") }
                        .buttonStyle(KavachButtonStyle(.quiet))
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func reputationBanner(_ e164: String) -> some View {
        if let rep = reputation {
            StatusBanner(tone: rep.isLikelyScam ? .danger : .caution,
                         systemImage: rep.isLikelyScam ? "xmark.octagon.fill" : "person.3.fill",
                         title: rep.text,
                         message: rep.isLikelyScam
                            ? "\(PhoneNumbers.formatted(e164)) is a likely scam. Don't call it back."
                            : "\(PhoneNumbers.formatted(e164)). Your report adds to theirs.")
        } else {
            StatusBanner(tone: .neutral, systemImage: "phone",
                         title: PhoneNumbers.formatted(e164),
                         message: "No one has reported this number yet. Your report helps warn others.")
        }
    }

    private func start(callerE164: String) {
        numberFocused = false
        // Same number again (came back from the questions): keep the incident already opened.
        if let incident, incident.callerE164 == callerE164 { goInterview = true; return }
        let draft = ReportDraft(personId: model.personId, callerE164: callerE164, startedAt: startedAt)
        Task {
            starting = true
            incident = await model.openReport(draft)
            starting = false
            goInterview = incident != nil
        }
    }
}
