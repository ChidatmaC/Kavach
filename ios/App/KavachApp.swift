import KavachKit
import SwiftUI

@main
struct KavachApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .kavachDisplay(model.prefs)
                .onOpenURL { url in handle(url) }
                .task {
                    model.startPolling()
                    await model.refreshNotificationStatus()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["KAVACH_DEBUG_CALL_FOLLOWUP"] == "1" {
                        CallFollowUpCenter.shared.debugShowPrompt()
                    }
                    #endif
                }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .active:
                model.reloadConfig()
                model.startPolling()
                CallFollowUpCenter.shared.appBecameActive()
                Task { await model.refreshNotificationStatus() }
            case .background:
                model.stopPolling()
                CallFollowUpCenter.shared.appEnteredBackground()
            default: break
            }
        }
    }

    /// kavach://companion, kavach://check, kavach://help (used by the Share extension "Open app"),
    /// kavach://report (Report a call).
    private func handle(_ url: URL) {
        switch url.host() {
        case "companion": model.route = .companion
        case "check": model.route = .check(prefill: nil)
        case "help": model.route = .needHelp
        case "report": model.route = .reportCall
        default: break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.shouldOfferAgentContact {
                AgentContactStepView()
            } else if model.isRegistered {
                MainTabs()
            } else {
                OnboardingView()
            }
        }
        .sheet(item: sheetRoute) { route in
            NavigationStack {
                switch route {
                case .check(let prefill): CheckMessageView(prefill: prefill ?? "")
                case .needHelp: NeedHelpView()
                case .actNow(let id): ActNowView(incidentId: id)
                case .interview(let id):
                    InterviewFlowView(incidentId: id, reportNumber: model.reportNumber(for: id))
                case .reportCall: ReportCallView()
                case .companion: EmptyView()
                }
            }
            .kavachDisplay(model.prefs)
            .environment(model)
        }
        .fullScreenCover(isPresented: companionPresented) {
            CallCompanionView()
                .kavachDisplay(model.prefs)
                .environment(model)
        }
    }

    private var sheetRoute: Binding<Route?> {
        Binding(get: { model.route == .companion ? nil : model.route },
                set: { if model.route != .companion { model.route = $0 } })
    }

    private var companionPresented: Binding<Bool> {
        Binding(get: { model.route == .companion }, set: { if !$0, model.route == .companion { model.route = nil } })
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "shield.lefthalf.filled", value: "home") { NavigationStack { HomeView() } }
            Tab("Network", systemImage: "point.3.connected.trianglepath.dotted", value: "network") {
                NavigationStack { NetworkDashboardView() }
            }
            Tab("Family", systemImage: "person.2", value: "family") { NavigationStack { FamilyView() } }
            Tab("Settings", systemImage: "gearshape", value: "settings") { NavigationStack { SettingsView() } }
        }
        .onAppear {
            #if DEBUG
            if let t = model.debugTab { tab = t }
            #endif
        }
    }
}
