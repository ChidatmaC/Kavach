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
                .task { model.startPolling() }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .active:
                model.reloadConfig()
                model.startPolling()
            case .background:
                model.stopPolling()
            default: break
            }
        }
    }

    /// kavach://companion, kavach://check, kavach://help (used by the Share extension "Open app").
    private func handle(_ url: URL) {
        switch url.host() {
        case "companion": model.route = .companion
        case "check": model.route = .check(prefill: nil)
        case "help": model.route = .needHelp
        default: break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isRegistered {
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
                case .interview(let id): InterviewFlowView(incidentId: id)
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

    var body: some View {
        TabView {
            Tab("Home", systemImage: "shield.lefthalf.filled") { NavigationStack { HomeView() } }
            Tab("This week", systemImage: "calendar") { NavigationStack { ThisWeekView() } }
            Tab("Family", systemImage: "person.2.fill") { NavigationStack { FamilyView() } }
            Tab("Settings", systemImage: "gearshape.fill") { NavigationStack { SettingsView() } }
        }
    }
}
