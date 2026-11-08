import KavachKit
import SwiftUI

/// Full-screen, high-contrast help during a call. Opening it calls `open_incident` with entry
/// `companion`, which tells the family (module side) and creates a reply request; the banner shows
/// that request live (told → seen by Tommy). When the call ends we speak a short check-in and open
/// the interview; "I've hung up" is the fallback if the CallKit event doesn't arrive.
struct CallCompanionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var incident: Incident?
    @State private var opening = true
    @State private var showInterview = false
    @State private var showVerify = false
    @State private var watcher = CallWatcher()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    familyStatus
                    companionCard(number: 1, icon: "lock", title: "Don't share codes",
                                  body: "No real bank, phone company or government will ask for a code, PIN or password.")
                    companionCard(number: 2, icon: "key", title: "Ask for our family code word",
                                  body: codeWordText)
                    companionCard(number: 3, icon: "phone.arrow.down.left", title: "Hang up and call back",
                                  body: "Call back on a number you already know, like the one on your card or in your contacts.")

                    VStack(spacing: Theme.Space.s) {
                        Button { showVerify = true } label: {
                            Label("Verify this person", systemImage: "person.badge.shield.checkmark")
                        }
                        .buttonStyle(CompanionButtonStyle(prominent: true))

                        Button { endAndReport() } label: {
                            Label("End and report", systemImage: "phone.down")
                        }
                        .buttonStyle(CompanionButtonStyle(prominent: false))

                        Button { callEnded(spoken: true) } label: {
                            Text("I've hung up")
                                .font(TypeScale.headline)
                                .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .foregroundStyle(Theme.accent)
                        .accessibilityHint("Use this if the call has ended")
                    }
                    .padding(.top, Theme.Space.xs)
                }
                .padding(Theme.Space.m)
            }
            .debugScrollAnchor()
            .kavachScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close Call Companion")
                }
            }
            .navigationTitle("Call Companion")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showInterview) {
                if let incident { InterviewFlowView(incidentId: incident.id) }
            }
            .sheet(isPresented: $showVerify) {
                NavigationStack { VerifyRelativeView() }
                    .kavachDisplay(model.prefs).environment(model)
            }
        }
        .preferredColorScheme(.dark)
        .task { await open() }
        .onAppear {
            watcher.onCallEnded = { callEnded(spoken: true) }
            watcher.start()
        }
        .onDisappear { watcher.stop() }
    }

    private var codeWordText: String {
        let w = model.person?.familyCodeWord ?? ""
        return w.isEmpty ? "Ask a question only your family would know. You can set a code word in Family."
                         : "Our code word is “\(w)”. If they don't know it, hang up."
    }

    /// Live: telling the family → told → seen by Tommy (or a warning if nobody answered).
    @ViewBuilder private var familyStatus: some View {
        if opening {
            HStack(spacing: Theme.Space.s) {
                ProgressView().tint(Theme.accent)
                Text("Telling your family…").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        } else if let incident {
            let request = model.alertRequest(for: incident.id)
            let progress = FamilyReplies.progress(for: request, contacts: model.contacts,
                                                  sharingPaused: model.person?.sharingPaused ?? false)
            let noFamily = request == nil && model.contacts.allSatisfy { $0.consentStatus != "accepted" }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    step("Told", done: progress.told, symbol: "paperplane")
                    Rectangle().fill(progress.seenBy != nil ? Theme.safe : Theme.separator).frame(height: 2)
                        .accessibilityHidden(true)
                    step(progress.seenBy.map { "Seen by \($0)" } ?? "Seen", done: progress.seenBy != nil, symbol: "eye")
                }
                Text(noFamily && !progress.told ? "No family member has accepted alerts yet. Add family in the Family tab."
                                                : progress.text)
                    .font(TypeScale.headline)
                    .foregroundStyle(progress.urgent ? Theme.caution : (progress.seenBy != nil ? Theme.safe : Theme.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(progress.urgent ? Theme.cautionSoft : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(progress.urgent ? Theme.caution : Theme.separator, lineWidth: progress.urgent ? 2 : 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your family: \(progress.text)")
            .accessibilityAddTraits(.updatesFrequently)
            .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: progress)
        } else {
            StatusBanner(tone: .caution, systemImage: "wifi.exclamationmark",
                         title: "Couldn't reach \(model.config.displayName)",
                         message: "The advice below still works. Hang up if you're unsure.")
        }
    }

    private func step(_ title: String, done: Bool, symbol: String) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : symbol)
            .font(TypeScale.callout.weight(.semibold))
            .foregroundStyle(done ? Theme.safe : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func companionCard(number: Int, icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.caution)
                .frame(width: Theme.Icon.l, height: Theme.Icon.l)
                .background(Theme.cautionSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Text(body).font(.title3).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            .strokeBorder(Theme.borderStrong, lineWidth: prefs.highContrast ? 2 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(title). \(body)")
    }

    private func open() async {
        guard incident == nil else { return }
        opening = true
        incident = await model.openIncident(entryPoint: "companion")
        opening = false
        if prefs.autoSpeak {
            Speaker.shared.speak("Don't share codes. Ask for the family code word. If unsure, hang up and call back on a number you know.")
        }
    }

    private func endAndReport() {
        Speaker.shared.stop()
        if incident != nil { showInterview = true }
    }

    private func callEnded(spoken: Bool) {
        guard !showInterview else { return }
        if spoken {
            Speaker.shared.speak("Your call has ended. Let's make sure you're okay. I'll ask five short questions.")
        }
        if incident != nil { showInterview = true }
    }
}

/// Large Companion buttons (64 pt): prominent = accent fill, otherwise outlined.
struct CompanionButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.displayPreferences) private var prefs

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)
            .background(prominent ? Theme.accentFill : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .strokeBorder(prominent ? Color.clear : Theme.borderStrong, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .sensoryFeedback(.impact(weight: .heavy), trigger: configuration.isPressed) { _, new in new && prefs.hapticsOnEveryTap }
    }
}
