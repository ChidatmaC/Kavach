import KavachKit
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result {
                        CheckResultView(result: result, message: text)
                        RepeatSpeechButton()
                        Button {
                            Speaker.shared.speak(CheckResultView(result: result, message: text).spokenText)
                        } label: { Label("Read aloud", systemImage: "speaker.wave.2.fill") }
                            .buttonStyle(KavachButtonStyle())
                    } else {
                        ProgressView(status)
                    }
                }
                .padding()
            }
            .navigationTitle("\(config.displayName) check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
        }
        .task { await run() }
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
