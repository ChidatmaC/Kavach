import KavachKit
import SwiftUI

/// Full-screen, high-contrast help during a call. Opening it calls `open_incident` with entry
/// `companion`, which tells the family (module side). When the call ends we speak a short check-in
/// and open the interview; "I've hung up" is the fallback if the CallKit event doesn't arrive.
struct CallCompanionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayPreferences) private var prefs
    @State private var incident: Incident?
    @State private var opening = true
    @State private var showInterview = false
    @State private var showVerify = false
    @State private var watcher = CallWatcher()

    private let yellow = Color(red: 1, green: 0.86, blue: 0.2)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    banner
                    companionCard(icon: "lock.fill", title: "Don't share codes",
                                  body: "No real bank, phone company or government will ask for a code, PIN or password.")
                    companionCard(icon: "key.fill", title: "Ask for our family code word",
                                  body: codeWordText)
                    companionCard(icon: "phone.down.fill", title: "Hang up and call back",
                                  body: "Call back on a number you already know, like the one on your card or in your contacts.")

                    Button { showVerify = true } label: {
                        Label("Verify this person", systemImage: "person.badge.shield.checkmark.fill")
                    }
                    .buttonStyle(CompanionButtonStyle(fill: yellow, text: .black))

                    Button { endAndReport() } label: {
                        Label("End and report", systemImage: "phone.down.circle.fill")
                    }
                    .buttonStyle(CompanionButtonStyle(fill: .white, text: .black))

                    Button { callEnded(spoken: true) } label: {
                        Label("I've hung up", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(CompanionButtonStyle(fill: .clear, text: .white))
                    .accessibilityHint("Use this if the call has ended")
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .foregroundStyle(.white)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                        .tint(.white)
                        .accessibilityLabel("Close Call Companion")
                }
            }
            .navigationTitle("Call Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
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

    @ViewBuilder private var banner: some View {
        if opening {
            ProgressView("Telling your family…").tint(.white)
        } else if incident != nil {
            let paused = model.person?.sharingPaused ?? false
            Label(paused ? "Sharing is paused, so your family wasn't told." : "Your family has been told you asked for help.",
                  systemImage: paused ? "pause.circle.fill" : "person.2.wave.2.fill")
                .font(.title3.weight(.semibold))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
        } else {
            Label("Couldn't reach \(model.config.displayName). The advice below still works.", systemImage: "wifi.exclamationmark")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white, lineWidth: 2))
        }
    }

    private func companionCard(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.title.weight(.heavy)).foregroundStyle(yellow)
            Text(body).font(.title3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.8), lineWidth: 2))
        .accessibilityElement(children: .combine)
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

struct CompanionButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    @Environment(\.displayPreferences) private var prefs

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(text)
            .background(fill, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .sensoryFeedback(.impact(weight: .heavy), trigger: configuration.isPressed) { _, new in new && prefs.hapticsOnEveryTap }
    }
}
