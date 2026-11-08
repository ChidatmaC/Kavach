import CallKit
import KavachKit
import SwiftUI

/// Settings: Accessibility Mode first; spoken verdicts, larger text; caller labels, text filter,
/// Action Button / Back Tap help; critical override and practice consent → `update_settings`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var labelStatus: CXCallDirectoryManager.EnabledStatus = .unknown

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.prefs.accessibilityMode },
                                     set: { v in Task { await model.setAccessibilityMode(v) } })) {
                    VStack(alignment: .leading) {
                        Text("Accessibility Mode").font(.headline)
                        Text("Bigger buttons and text, higher contrast, results read aloud, a tap you can feel.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Theme.minTarget)
                Toggle("Read results aloud", isOn: $model.prefs.spokenVerdicts)
                    .frame(minHeight: Theme.minTarget)
                    .onChange(of: model.prefs.spokenVerdicts) { model.savePrefs() }
                Toggle("Larger text", isOn: $model.prefs.largerText)
                    .frame(minHeight: Theme.minTarget)
                    .onChange(of: model.prefs.largerText) { model.savePrefs() }
            } header: {
                Text("Accessibility")
            }

            Section {
                HStack {
                    Label("Caller labels", systemImage: "phone.badge.waveform")
                    Spacer()
                    Text(labelStatusText).foregroundStyle(labelStatus == .enabled ? Theme.safe : .secondary)
                }
                .frame(minHeight: Theme.minTarget)
                .accessibilityElement(children: .combine)
                Text("Turn on: Settings → Apps → Phone → Call Blocking & Identification → \(model.config.displayName). Incoming scam calls then say “Likely scam: N reports.” \(model.callerLabelCount) numbers loaded.")
                    .font(.footnote)
                Button("Refresh caller labels now") {
                    Task { await model.refreshLabelsAndCampaigns(); CallDirectoryReloader.reload(); await loadStatus() }
                }
                .frame(minHeight: Theme.minTarget)
                Label("Text filter", systemImage: "line.3.horizontal.decrease.circle").frame(minHeight: Theme.minTarget)
                Text("Turn on: Settings → Apps → Messages → Unknown Senders → Text Message Filter → \(model.config.displayName). Likely scam texts from unknown senders go to Junk.")
                    .font(.footnote)
                Label("Report calls from Recents", systemImage: "exclamationmark.bubble").frame(minHeight: Theme.minTarget)
                Text("Turn on: Settings → Apps → Phone → SMS/Call Reporting → \(model.config.displayName). Then swipe left on a call in Recents and tap Report.")
                    .font(.footnote)
            } header: {
                Text("Calls and texts")
            }

            Section {
                Text("Action Button: Settings → Action Button → Shortcut → \(model.config.displayName) → Open Call Companion.")
                Text("Back Tap: Settings → Accessibility → Touch → Back Tap → Double Tap → Open Call Companion.")
                Text("Siri: say “Open Call Companion in \(model.config.displayName)”, “Check this with \(model.config.displayName)” or “I need help in \(model.config.displayName)”.")
            } header: {
                Text("One-press help")
            }
            .font(.body)

            Section {
                Toggle(isOn: Binding(get: { model.person?.criticalOverridesPause ?? false },
                                     set: { v in Task { await model.updateSettings { $0.criticalOverridesPause = v } } })) {
                    VStack(alignment: .leading) {
                        Text("Always tell my emergency contact in an emergency")
                        Text("Even when sharing is paused.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Theme.minTarget)
                Toggle(isOn: Binding(get: { model.person?.practiceConsent ?? false },
                                     set: { v in Task { await model.updateSettings { $0.practiceConsent = v } } })) {
                    VStack(alignment: .leading) {
                        Text("Allow practice scams")
                        Text("Harmless practice texts from family, revealed right away.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Theme.minTarget)
            } header: {
                Text("Family safety")
            }

            Section {
                NavigationLink("Server settings") { ServerSettingsView() }.frame(minHeight: Theme.minTarget)
                if let p = model.person { LabeledContent("Signed in as", value: "\(p.displayName) · \(p.phoneE164)") }
                Button("Sign out of this phone", role: .destructive) { model.signOut() }.frame(minHeight: Theme.minTarget)
            } header: {
                Text("Advanced")
            }
            if let e = model.lastError { Text(e).foregroundStyle(Theme.amber) }
        }
        .navigationTitle("Settings")
        .task { await loadStatus() }
    }

    private var labelStatusText: String {
        switch labelStatus {
        case .enabled: "On"
        case .disabled: "Off"
        default: "Unknown"
        }
    }

    private func loadStatus() async { labelStatus = await CallDirectoryReloader.status() }
}

/// Backend addresses (App Group overrides of the xcconfig defaults). On a real iPhone, use the
/// Mac's LAN IP, e.g. http://192.168.1.20:3000.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var stdb = ""
    @State private var agents = ""
    @State private var db = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section("SpacetimeDB") {
                TextField("http://192.168.1.20:3000", text: $stdb).keyboardType(.URL).textInputAutocapitalization(.never)
                TextField("Database name", text: $db).textInputAutocapitalization(.never)
            }
            Section("Agent service") {
                TextField("http://192.168.1.20:8088", text: $agents).keyboardType(.URL).textInputAutocapitalization(.never)
            }
            Button("Save") {
                let s = SharedStore(appGroup: model.config.appGroup)
                s.set(stdb, .spacetimeURLOverride)
                s.set(agents, .agentURLOverride)
                s.set(db, .databaseOverride)
                model.reloadConfig()
                Task {
                    let ok = await AgentClient(baseURL: model.config.agentURL).health()
                    status = "Saved. Agent service: \(ok ? "reachable" : "not reachable")."
                }
            }
            .frame(minHeight: Theme.minTarget)
            Button("Use build defaults") {
                let s = SharedStore(appGroup: model.config.appGroup)
                s.remove(.spacetimeURLOverride); s.remove(.agentURLOverride); s.remove(.databaseOverride)
                model.reloadConfig()
                load()
            }
            .frame(minHeight: Theme.minTarget)
            if let status { Text(status) }
        }
        .navigationTitle("Server settings")
        .onAppear(perform: load)
    }

    private func load() {
        stdb = model.config.spacetimeURL.absoluteString
        agents = model.config.agentURL.absoluteString
        db = model.config.databaseName
    }
}
