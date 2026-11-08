import KavachKit
import SwiftUI

/// Verify a relative → `/app/verify`. The agent texts the relative's saved number and starts the
/// deadline; the reply request then shows on Home ("Waiting for Tommy to confirm…").
struct VerifyRelativeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var result: VerifyResult?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Who do they say they are? We'll ask that person on their own number.")
                    .font(.title3).foregroundStyle(Theme.textPrimary)

                if !model.contacts.isEmpty {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(model.contacts) { c in
                            Button { Task { await verify(c.name) } } label: {
                                HStack(spacing: Theme.Space.s) {
                                    MonogramAvatar(name: c.name, size: 36, imageData: model.contactsBridge.photos[c.id])
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                                        if !c.relationship.isEmpty {
                                            Text(c.relationship).font(.subheadline).foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                                }
                                .padding(Theme.Space.s)
                                .frame(minHeight: 56)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.separator))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("Verify \(c.name)")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Someone else").font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                    TextField("Their name", text: $name)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: 48)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.borderStrong.opacity(0.6)))
                }
                Button("Verify \(name.isEmpty ? "this person" : name)") { Task { await verify(name) } }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)

                if busy { ProgressView("Asking them…").tint(Theme.accent) }
                if let result {
                    StatusBanner(tone: .info, systemImage: "hourglass", title: "We're checking",
                                 message: result.messages.isEmpty
                                    ? "We've asked them. You'll get a text when they answer. Until then, don't send anything."
                                    : result.messages.joined(separator: "\n"))
                }
                if let error {
                    StatusBanner(tone: .caution, systemImage: "exclamationmark.triangle",
                                 title: "Couldn't start the check",
                                 message: "Hang up, then call them yourself on the number you know. Don't send money or codes. (\(error))")
                }
            }
            .padding(Theme.Space.m)
        }
        .kavachScreenBackground()
        .navigationTitle("Verify a relative")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }

    private func verify(_ who: String) async {
        guard let api = model.api else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            result = try await api.verifyRelative(name: who)
            if model.prefs.autoSpeak { Speaker.shared.speak(result?.messages.joined(separator: " ") ?? "") }
            await model.refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
