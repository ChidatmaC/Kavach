import KavachKit
import MessageUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share extension: shared text, links or a screenshot → `/app/check` (source "share"), verdict
/// shown in the share sheet.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let config = AppConfig.current
        let prefs = DisplayPreferences.load(from: SharedStore(appGroup: config.appGroup))
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let root = ShareRootView(config: config, providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        .kavachDisplay(prefs)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareRootView: View {
    let config: AppConfig
    let providers: [NSItemProvider]
    let close: @MainActor () -> Void

    @State private var text = ""
    @State private var result: CheckResult?
    @State private var status = "Reading what you shared…"
    @State private var composing = false
    @State private var copiedForward = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let result {
                        Card { CheckResultView(result: result, message: text) }
                        HStack(spacing: Theme.Space.s) {
                            Button {
                                Speaker.shared.speak(CheckResultView(result: result, message: text).spokenText)
                            } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
                                .buttonStyle(KavachButtonStyle(.secondary))
                            Button("Done") { close() }
                                .buttonStyle(KavachButtonStyle(.primary))
                        }
                        if !config.agentLineNumber.isEmpty && !text.isEmpty {
                            Button(action: forward) {
                                Label("Text it to \(config.displayName)", systemImage: "arrowshape.turn.up.right")
                            }
                            .buttonStyle(KavachButtonStyle(.secondary))
                            .accessibilityHint("Opens a text to \(AgentContact.formatted(config.agentLineNumber)) with the message filled in")
                            if copiedForward {
                                Label("Copied. Paste in Messages to \(AgentContact.formatted(config.agentLineNumber)).",
                                      systemImage: "doc.on.clipboard")
                                    .font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        RepeatSpeechButton()
                        if let api = KavachAPI.stored(config: config) {
                            VerdictFeedbackControl(verdict: result.verdict) { fb in
                                await api.sendFeedback(fb, checkId: result.checkId, requestKey: result.requestKey)
                            }
                        }
                    } else {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().tint(Theme.accent)
                            Text(status).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                        }
                        .padding(.top, Theme.Space.l)
                    }
                }
                .padding(Theme.Space.m)
            }
            .kavachScreenBackground()
            .navigationTitle("\(config.displayName) check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
        }
        .task { await run() }
        .sheet(isPresented: $composing) {
            MessageComposer(recipient: config.agentLineNumber, body: ForwardToKavach.wrap(text)) { composing = false }
                .ignoresSafeArea()
        }
    }

    /// Share extensions can't open URLs, so compose the text here. Where Messages isn't available
    /// (e.g. Simulator), copy the wrapped text for the person to paste.
    private func forward() {
        if MFMessageComposeViewController.canSendText() {
            composing = true
        } else {
            UIPasteboard.general.string = ForwardToKavach.wrap(text)
            copiedForward = true
        }
    }

    private func run() async {
        text = await Self.extractText(from: providers)
        guard !text.isEmpty else {
            result = CheckResult(verdict: .suspicious, reason: "I couldn't read anything to check. Try copying the text into \(config.displayName).")
            return
        }
        guard let api = KavachAPI.stored(config: config) else {
            result = CheckResult(verdict: .suspicious, reason: "Open \(config.displayName) once to set it up. Until then, don't reply or tap any links.")
            return
        }
        status = "Checking…"
        result = await api.check(text: text, source: .share)
    }

    static func extractText(from providers: [NSItemProvider]) async -> String {
        var parts: [String] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await load(Data.self, from: p),
                   let s = try? await TextRecognizer.recognize(imageData: data), !s.isEmpty { parts.append(s) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let u = await load(URL.self, from: p) { parts.append(u.absoluteString) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let s = await load(String.self, from: p) { parts.append(s) }
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { cont in
            _ = provider.loadTransferable(type: T.self) { result in cont.resume(returning: try? result.get()) }
        }
    }
}

/// Messages compose sheet with the agent number and the wrapped body filled in.
struct MessageComposer: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let done: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let done: @MainActor () -> Void
        init(done: @escaping @MainActor () -> Void) { self.done = done }
        nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                                      didFinishWith result: MessageComposeResult) {
            MainActor.assumeIsolated { done() } // MessageUI calls its delegate on the main thread
        }
    }
}
