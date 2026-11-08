import KavachKit
import PhotosUI
import SwiftUI

/// Check a message: paste or screenshot (on-device text recognition) → `/app/check`.
struct CheckMessageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var prefill: String
    @State private var text = ""
    @State private var sender = ""
    @State private var source: CheckSource = .appPaste
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    @State private var checking = false
    @State private var result: CheckResult?
    @State private var status: String?

    init(prefill: String = "") { _prefill = State(initialValue: prefill) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result {
                    CheckResultView(result: result, message: text)
                    RepeatSpeechButton()
                    resultActions(result)
                    Button("Check another message") { reset() }
                        .buttonStyle(KavachButtonStyle())
                } else {
                    input
                }
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).accessibilityLabel(status)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Check a message")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear { if !prefill.isEmpty { text = prefill; prefill = "" } }
        .onChange(of: photo) { _, item in if let item { Task { await readScreenshot(item) } } }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste the message, or choose a screenshot of it.").font(.title3)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 160)
                .padding(6)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("The message goes here").foregroundStyle(.secondary).padding(14).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Message to check")
            HStack(spacing: 12) {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        text = strings.joined(separator: "\n")
                        source = .appPaste
                    }
                }
                .labelStyle(.titleAndIcon)
                .frame(minHeight: Theme.minTarget)
                .accessibilityLabel("Paste")
                PhotosPicker(selection: $photo, matching: .screenshots) {
                    Label("Choose screenshot", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(KavachButtonStyle())
                .accessibilityLabel("Choose screenshot")
            }
            if reading { ProgressView("Reading the screenshot…") }
            TextField("Who sent it? (optional phone number)", text: $sender)
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: Theme.minTarget)
                .accessibilityLabel("Sender phone number, optional")
            Button {
                Task { await check() }
            } label: {
                if checking { ProgressView() } else { Label("Check it", systemImage: "checkmark.shield") }
            }
            .buttonStyle(KavachButtonStyle(prominent: true))
            .disabled(checking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private func resultActions(_ r: CheckResult) -> some View {
        VStack(spacing: 10) {
            if r.verdict != .safe {
                Button { Task { await reportAndBlock() } } label: {
                    Label("Report and block", systemImage: "hand.raised.slash.fill")
                }
                .buttonStyle(KavachButtonStyle(prominent: true, tint: r.verdict == .likelyScam ? Theme.danger : Theme.accent))
            }
            Button { Task { await tellFamily(r) } } label: { Label("Tell my family", systemImage: "person.2.fill") }
                .buttonStyle(KavachButtonStyle())
            Button {
                Speaker.shared.speak(CheckResultView(result: r, message: text).spokenText)
            } label: { Label("Read aloud", systemImage: "speaker.wave.2.fill") }
                .buttonStyle(KavachButtonStyle())
        }
    }

    private func readScreenshot(_ item: PhotosPickerItem) async {
        reading = true
        defer { reading = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            status = "Couldn't open that picture."; return
        }
        do {
            let recognized = try await TextRecognizer.recognize(imageData: data)
            if recognized.isEmpty { status = "I couldn't find any words in that picture." }
            text = recognized
            source = .screenshot
        } catch {
            status = "Couldn't read that picture."
        }
    }

    private func check() async {
        guard let api = model.api else { return }
        checking = true
        defer { checking = false }
        let s = normalizePhone(sender)
        result = await api.check(text: text, source: source, senderE164: s.isEmpty ? nil : s)
        await model.refresh()
    }

    /// Report the sender number and any links as community reports. iOS doesn't let apps block
    /// numbers, so we explain how.
    private func reportAndBlock() async {
        let s = normalizePhone(sender)
        var reported = 0
        if !s.isEmpty, await model.run({ try await $0.reportValue(personId: model.personId, kind: "number", value: s) }) {
            reported += 1
        }
        for link in Highlighter.links(in: text).prefix(3) {
            if await model.run({ try await $0.reportValue(personId: model.personId, kind: "link", value: link.absoluteString) }) {
                reported += 1
            }
        }
        status = (reported > 0 ? "Thanks, it's reported. " : "")
            + "To block the sender: open the message, tap their name, then Block Caller. Then delete the message."
        if model.prefs.autoSpeak, let status { Speaker.shared.speak(status) }
    }

    /// The module only alerts family about incidents, so this files a short "app" incident that
    /// says the person did not engage, then asks the module to tell the family (tell_my_family).
    private func tellFamily(_ r: CheckResult) async {
        guard let inc = await model.openIncident(entryPoint: "app", callerE164: normalizePhone(sender)) else {
            status = model.lastError; return
        }
        let ok = await model.run { api in
            try await api.saveAnswer(incidentId: inc.id, questionId: "q_engaged", answer: "no")
            try await api.saveAnswer(incidentId: inc.id, questionId: "q_summary",
                                     answer: "Checked a message in the app: \(r.verdict.word). \(r.reason)")
            try await api.tellMyFamily(incidentId: inc.id)
        }
        status = ok ? "Your family will get a short note about this." : (model.lastError ?? "Couldn't tell your family.")
    }

    private func reset() {
        result = nil; text = ""; sender = ""; status = nil; source = .appPaste
        Speaker.shared.stop()
    }
}
