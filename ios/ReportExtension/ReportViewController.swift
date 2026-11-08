import IdentityLookup
import IdentityLookupUI
import KavachKit
import Observation
import SwiftUI
import UIKit

/// Unwanted Communication (Report) extension: when a call is reported from Recents, it shows the
/// shared interview. This extension point has no network access, so answers are collected locally
/// and returned in `ILClassificationResponse.userInfo` (`{token, caller_e164, answers, reported_at,
/// request_key}`); iOS POSTs that to `ILClassificationExtensionNetworkReportDestination`
/// (`<AGENT_SERVICE_URL>/ios/call-report`). The report is also saved in the App Group so the app
/// replays it through the normal reducers if the POST never arrived (docs/CONTRACTS.md section 7).
/// The system Done/Report button is enabled only after every question is answered.
final class ReportViewController: ILClassificationUIExtensionViewController {
    private let session = ReportSession()
    private var config = AppConfig.current

    override func viewDidLoad() {
        super.viewDidLoad()
        extensionContext.isReadyForClassificationResponse = false
    }

    override func prepare(for classificationRequest: ILClassificationRequest) {
        config = AppConfig.current
        let store = SharedStore(appGroup: config.appGroup)
        session.token = store.loadToken()
        if let call = classificationRequest as? ILCallClassificationRequest {
            session.isCall = true
            session.callerE164 = normalizePhone(call.callCommunications.last?.sender ?? "")
        } else {
            session.isCall = false
        }
        session.onReady = { [weak self] in self?.extensionContext.isReadyForClassificationResponse = true }
        // Nothing to ask (not set up, or a text): let the person finish right away.
        if !session.isCall || session.token == nil { extensionContext.isReadyForClassificationResponse = true }
        show()
    }

    override func classificationResponse(for request: ILClassificationRequest) -> ILClassificationResponse {
        guard session.isCall else { return ILClassificationResponse(action: .none) }
        let response = ILClassificationResponse(action: .reportJunk)
        if let report = session.report() {
            response.userInfo = report.userInfo
            CallReportStore(store: SharedStore(appGroup: config.appGroup)).save(report)
        }
        return response
    }

    private func show() {
        let prefs = DisplayPreferences.load(from: SharedStore(appGroup: config.appGroup))
        let root = ReportRootView(config: config, session: session).kavachDisplay(prefs)
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

/// Answers collected on the phone while the extension is open.
@MainActor
@Observable
final class ReportSession {
    var token: String?
    var callerE164 = ""
    var isCall = true
    var answers: [String: String] = [:]
    var finished = false
    let reportedAt = Date()
    @ObservationIgnored var onReady: (() -> Void)?

    func finish() {
        finished = true
        onReady?()
    }

    func report() -> CallReport? {
        guard let token else { return nil }
        return CallReport(token: token, callerE164: callerE164, answers: answers, reportedAt: reportedAt)
    }
}

struct ReportRootView: View {
    let config: AppConfig
    let session: ReportSession

    var body: some View {
        NavigationStack {
            Group {
                if !session.isCall {
                    message(icon: "text.bubble", tone: .info, title: "Texts: use Check a message",
                            body: "Open \(config.displayName) and use Check a message, or share the text to \(config.displayName).")
                } else if session.token == nil {
                    message(icon: "exclamationmark.triangle", tone: .caution, title: "Set up \(config.displayName) first",
                            body: "Open \(config.displayName) once to set it up. You can still tap Report to report this number to Apple.")
                } else if session.finished {
                    message(icon: "checkmark.shield", tone: .success, title: "Thank you",
                            body: "Tap Report to send it. It helps protect others, and \(config.displayName) will show your next steps when you open it.")
                } else {
                    VStack(spacing: 0) {
                        if !session.callerE164.isEmpty {
                            Label("Reporting \(PhoneNumbers.formatted(session.callerE164))", systemImage: "phone.down")
                                .font(TypeScale.callout.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)
                                .background(Theme.background)
                        }
                        InterviewView(title: "Report this call", save: { qid, answer in
                            session.answers[qid] = answer
                        }, onDone: {
                            session.finish()
                        })
                    }
                }
            }
        }
    }

    private func message(icon: String, tone: StatusTone, title: String, body: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                IconTile(icon, tone: tone, size: 56)
                Text(title).font(TypeScale.display).foregroundStyle(Theme.textPrimary)
                Text(body).font(.title3).foregroundStyle(Theme.textPrimary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .kavachScreenBackground()
    }
}
