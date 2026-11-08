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
    @FocusState private var focused: Field?

    enum Field { case message, sender }

    init(prefill: String = "") { _prefill = State(initialValue: prefill) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let result {
                    Card { CheckResultView(result: result, message: text) }
                    resultActions(result)
                    VerdictFeedbackControl(verdict: result.verdict) { fb in
                        await model.sendFeedback(fb, for: result)
                    }
                    .padding(.horizontal, Theme.Space.xxs)
                } else {
                    input
                }
                if let status {
                    StatusBanner(tone: .neutral, systemImage: "info.circle", title: status)
                }
            }
            .padding(Theme.Space.m)
        }
        .debugScrollAnchor()
        .scrollDismissesKeyboard(.interactively)
        .kavachScreenBackground()
        .navigationTitle(result == nil ? "Check a message" : "Result")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            if result != nil {
                ToolbarItem(placement: .primaryAction) { Button("Check another") { reset() } }
            }
        }
        .onAppear {
            if !prefill.isEmpty { text = prefill; prefill = "" }
            #if DEBUG
            if ProcessInfo.processInfo.environment["KAVACH_DEBUG_AUTOCHECK"] == "1", !text.isEmpty, result == nil {
                Task { await check() }
            }
            #endif
        }
        .onChange(of: photo) { _, item in if let item { Task { await readScreenshot(item) } } }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Paste the message, or choose a screenshot of it. We'll tell you if it looks like a scam.")
                .font(TypeScale.body).foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Message").font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $text)
                    .font(TypeScale.body)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focused, equals: .message)
                    .frame(minHeight: 160)
                    .padding(Theme.Space.xs)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                            .strokeBorder(focused == .message ? Theme.accent : Theme.borderStrong.opacity(0.6),
                                          lineWidth: focused == .message ? 2 : 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("The message goes here").foregroundStyle(Theme.textSecondary)
                                .padding(Theme.Space.m).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Message to check")
            }

            HStack(spacing: Theme.Space.s) {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        text = strings.joined(separator: "\n")
                        source = .appPaste
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.m))
                .tint(Theme.accentFill)
                .frame(minHeight: Theme.minTarget)
                PhotosPicker(selection: $photo, matching: .screenshots) {
                    Label("Screenshot", systemImage: "photo")
                }
                .buttonStyle(KavachButtonStyle(.secondary))
                .accessibilityLabel("Choose a screenshot")
            }
            if reading {
                ProgressView("Reading the screenshot…").tint(Theme.accent)
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Who sent it? (optional)").font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                TextField("Phone number", text: $sender)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focused, equals: .sender)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(minHeight: 48)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                            .strokeBorder(focused == .sender ? Theme.accent : Theme.borderStrong.opacity(0.6),
                                          lineWidth: focused == .sender ? 2 : 1)
                    }
                    .accessibilityLabel("Sender phone number, optional")
            }

            Button {
                focused = nil
                Task { await check() }
            } label: {
                if checking {
                    HStack(spacing: Theme.Space.xs) { ProgressView().tint(Theme.onAccent); Text("Checking…") }
                } else {
                    Label("Check it", systemImage: "checkmark.shield")
                }
            }
            .buttonStyle(KavachButtonStyle(.primary))
            .disabled(checking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private func resultActions(_ r: CheckResult) -> some View {
        VStack(spacing: Theme.Space.s) {
            if r.verdict != .safe {
                Button { Task { await reportAndBlock() } } label: {
                    Label("Report and block", systemImage: "hand.raised")
                }
                .buttonStyle(KavachButtonStyle(r.verdict == .likelyScam ? .destructive : .primary))
            }
            HStack(spacing: Theme.Space.s) {
                Button { Task { await tellFamily(r) } } label: { Label("Tell my family", systemImage: "person.2") }
                    .buttonStyle(KavachButtonStyle(r.verdict == .safe ? .primary : .secondary))
                Button {
                    Speaker.shared.speak(CheckResultView(result: r, message: text).spokenText)
                } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
                    .buttonStyle(KavachButtonStyle(.secondary))
            }
            if !model.agentNumber.isEmpty {
                ForwardByTextButton(message: text, from: sender)
            }
            RepeatSpeechButton()
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
        status = nil
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
