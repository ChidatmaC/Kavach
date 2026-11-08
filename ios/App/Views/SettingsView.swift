import CallKit
import KavachKit
import SwiftUI
import UIKit

/// Settings: Accessibility Mode first; spoken verdicts, larger text; family safety; Contacts;
/// caller labels, text filter and call reporting; Action Button / Back Tap help → `update_settings`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var labelStatus: CXCallDirectoryManager.EnabledStatus = .unknown

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                // Reads the person row (optimistic + polled), not a local copy.
                SettingToggleRow(.accessibilityMode, title: "Accessibility Mode",
                                 detail: "Bigger buttons and text, higher contrast, results read aloud, a tap you can feel. Home shows just the three main actions.",
                                 isOn: model.binding(for: .accessibilityMode))
                SettingToggleRow(.spokenVerdicts, title: "Read results aloud", isOn: $model.localPrefs.spokenVerdicts)
                    .onChange(of: model.localPrefs.spokenVerdicts) { model.savePrefs() }
                SettingToggleRow(.largerText, title: "Larger text", isOn: $model.localPrefs.largerText)
                    .onChange(of: model.localPrefs.largerText) { model.savePrefs() }
            } header: {
                Text("Accessibility")
            }
            .listRowBackground(Theme.surface)

            Section {
                AgentContactRows()
            } header: {
                Text("\(model.config.displayName) on iMessage")
            } footer: {
                Text("Text any message you're unsure about to \(AgentContact.formatted(model.agentNumber)). You'll get an answer in a minute. \(ForwardToKavach.helpText(appName: model.config.displayName))")
            }
            .listRowBackground(Theme.surface)

            Section {
                SettingToggleRow(.sharingPaused, title: "Pause family alerts",
                                 detail: "You can also text “pause” or “resume” to \(model.config.displayName).",
                                 isOn: model.binding(for: .sharingPaused))
                SettingToggleRow(.criticalOverridesPause, title: "Always tell my emergency contact in an emergency",
                                 detail: "Even when family alerts are paused.",
                                 isOn: model.binding(for: .criticalOverridesPause))
            } header: {
                Text("Family safety")
            }
            .listRowBackground(Theme.surface)

            Section {
                ContactsIntegrationRow()
            } header: {
                Text("Contacts")
            } footer: {
                Text("Optional. Your address book stays on this phone; only family members you add are shared.")
            }
            .listRowBackground(Theme.surface)

            Section {
                SetupRow(icon: "phone.badge.waveform", title: "Caller labels",
                         status: labelStatusText, statusOn: labelStatus == .enabled,
                         steps: "Settings → Apps → Phone → Call Blocking & Identification → \(model.config.displayName). Scam calls then say “Likely scam: N reports.” \(model.callerLabelCount) numbers loaded.")
                Button("Refresh caller labels now") {
                    Task { await model.refreshLabelsAndCampaigns(); CallDirectoryReloader.reload(); await loadStatus() }
                }
                .frame(minHeight: Theme.minTarget)
                SetupRow(icon: "exclamationmark.bubble", title: "Report calls from Recents", status: nil, statusOn: false,
                         steps: "Settings → Apps → Phone → Call Blocking & Identification → \(model.config.displayName), and Settings → Apps → Phone → SMS/Call Reporting → \(model.config.displayName). Then in Phone → Recents, swipe left on a call and tap Report.")
                SetupRow(icon: "line.3.horizontal.decrease.circle", title: "Text filter", status: nil, statusOn: false,
                         steps: "Settings → Apps → Messages → Unknown Senders → Text Message Filter → \(model.config.displayName). Likely scam texts from unknown senders go to Junk.")
            } header: {
                Text("Calls and texts")
            }
            .listRowBackground(Theme.surface)

            Section {
                SetupRow(icon: "button.horizontal.top.press", title: "Action Button", status: nil, statusOn: false,
                         steps: "Settings → Action Button → Shortcut → \(model.config.displayName) → Open Call Companion.")
                SetupRow(icon: "hand.tap", title: "Back Tap", status: nil, statusOn: false,
                         steps: "Settings → Accessibility → Touch → Back Tap → Double Tap → Open Call Companion.")
                SetupRow(icon: "mic", title: "Siri", status: nil, statusOn: false,
                         steps: "Say “Open Call Companion in \(model.config.displayName)”, “Check this with \(model.config.displayName)” or “I need help in \(model.config.displayName)”.")
            } header: {
                Text("One-press help")
            }
            .listRowBackground(Theme.surface)

            Section {
                NavigationLink("Server settings") { ServerSettingsView() }.frame(minHeight: Theme.minTarget)
                if let p = model.person {
                    LabeledContent("Signed in as", value: "\(p.displayName) · \(PhoneNumbers.formatted(p.phoneE164))")
                }
                Button("Sign out of this phone", role: .destructive) { Task { await model.signOut() } }.frame(minHeight: Theme.minTarget)
            } header: {
                Text("Advanced")
            }
            .listRowBackground(Theme.surface)

            if let e = model.lastError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.caution)
                    .accessibilityLabel("Problem: \(e)")
                    .listRowBackground(Theme.surface)
            }
        }
        .debugScrollAnchor()
        .scrollContentBackground(.hidden)
        .kavachScreenBackground()
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

/// An iOS setting the person turns on themselves: icon, title, optional status, the path to it.
struct SetupRow: View {
    let icon: String
    let title: String
    let status: String?
    let statusOn: Bool
    let steps: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: Theme.Icon.s).accessibilityHidden(true)
                Text(title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                if let status {
                    StatusPill(status, systemImage: statusOn ? "checkmark.circle.fill" : "minus.circle",
                               tone: statusOn ? .success : .neutral)
                }
            }
            Text(steps).font(.subheadline).foregroundStyle(Theme.textSecondary)
                .padding(.leading, Theme.Icon.s + Theme.Space.s)
        }
        .padding(.vertical, Theme.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// Opt-in Contacts access (photos, name sync, suggestions). Asks iOS only when turned on.
struct ContactsIntegrationRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let bridge = model.contactsBridge
        let isOn = Binding(get: { bridge.isActive }, set: { on in
            Task {
                if on {
                    if await bridge.enable() { await model.syncContacts(force: true) }
                    else if bridge.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else { bridge.disable() }
            }
        })
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: bridge.isActive ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(bridge.isActive ? Theme.safe : Theme.textSecondary)
                    .frame(width: Theme.Icon.s)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Contacts").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text(bridge.isActive ? "Photos and names from Contacts"
                         : (bridge.status == .denied ? "Contacts access is off in iOS Settings" : "Not using Contacts"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(bridge.isActive ? Theme.safe : Theme.textSecondary)
                    Text("Shows family photos, keeps names up to date and suggests family members.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(minHeight: Theme.minTarget)
    }
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
