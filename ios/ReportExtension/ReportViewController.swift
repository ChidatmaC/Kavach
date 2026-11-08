import IdentityLookup
import IdentityLookupUI
import KavachKit
import SwiftUI
import UIKit

/// Unwanted Communication (Report) extension: when a call is reported from Recents, host the shared
/// interview, calling `open_incident` (entry `report_swipe`, caller number) and `save_answer`.
/// SMS reporting is reported broken on iOS 26, so texts get a pointer to Check a message instead.
final class ReportViewController: ILClassificationUIExtensionViewController {
    private var callerE164 = ""
    private var isCall = true
    private var reportedNumber = false

    override func viewDidLoad() {
        super.viewDidLoad()
        extensionContext.isReadyForClassificationResponse = false
    }

    override func prepare(for classificationRequest: ILClassificationRequest) {
        if let call = classificationRequest as? ILCallClassificationRequest {
            isCall = true
            callerE164 = normalizePhone(call.callCommunications.last?.sender ?? "")
        } else {
            isCall = false
        }
        show()
    }

    override func classificationResponse(for request: ILClassificationRequest) -> ILClassificationResponse {
        ILClassificationResponse(action: isCall ? .reportJunk : .none)
    }

    private func show() {
        let config = AppConfig.current
        let prefs = DisplayPreferences.load(from: SharedStore(appGroup: config.appGroup))
        let root = ReportRootView(
            config: config, callerE164: callerE164, isCall: isCall,
            onFinished: { [weak self] in self?.extensionContext.isReadyForClassificationResponse = true }
        )
        .kavachDisplay(prefs)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

struct ReportRootView: View {
    let config: AppConfig
    let callerE164: String
    let isCall: Bool
    let onFinished: @MainActor () -> Void

    enum Phase { case starting, interview(UInt64), done, failed(String), textMessage }
    @State private var phase: Phase = .starting

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .starting:
                    ProgressView("Starting your report…")
                case .interview(let id):
                    InterviewView(title: "Report this call", save: { qid, answer in
                        guard let api = KavachAPI.stored(config: config) else { throw KavachError.notRegistered }
                        try await api.saveAnswer(incidentId: id, questionId: qid, answer: answer)
                    }, onDone: {
                        phase = .done
                        onFinished()
                    })
                case .done:
                    message(icon: "checkmark.shield.fill", title: "Thank you",
                            body: "Your report is saved and helps protect others. Tap Report to finish. Open \(config.displayName) to see any next steps.")
                case .failed(let why):
                    message(icon: "exclamationmark.triangle.fill", title: "Couldn't start the report",
                            body: "\(why) You can still tap Report to block this number.")
                case .textMessage:
                    message(icon: "text.bubble.fill", title: "Texts: use Check a message",
                            body: "Open \(config.displayName) and use Check a message, or share the text to \(config.displayName).")
                }
            }
            .padding(.top)
        }
        .task { await start() }
    }

    private func message(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.title.weight(.bold)).foregroundStyle(Theme.accent)
            Text(body).font(.title3)
            Spacer()
        }
        .padding()
    }

    private func start() async {
        guard isCall else { phase = .textMessage; onFinished(); return }
        let store = SharedStore(appGroup: config.appGroup)
        guard let api = KavachAPI.stored(config: config), store.uint64(.personId) != 0 else {
            phase = .failed("Open \(config.displayName) once to set it up.")
            onFinished()
            return
        }
        do {
            let inc = try await api.openIncident(personId: store.uint64(.personId), entryPoint: "report_swipe",
                                                 callerE164: callerE164)
            phase = .interview(inc.id)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "")
            onFinished()
        }
    }
}
