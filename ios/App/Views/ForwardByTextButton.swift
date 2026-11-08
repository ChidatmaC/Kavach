import KavachKit
import SwiftUI
import UIKit

/// "Send to Kavach by text": opens Messages to the agent with the message wrapped as
/// "Forwarded message: …" (`ForwardToKavach`). If Messages can't open (e.g. Simulator), the wrapped
/// text is copied so the person can paste it.
struct ForwardByTextButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let message: String
    var from: String = ""
    /// Button title; nil = "Send to <app> by text".
    var title: String? = nil
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button(action: send) {
                Label(title ?? "Send to \(model.config.displayName) by text", systemImage: "arrowshape.turn.up.right")
            }
            .buttonStyle(KavachButtonStyle(.secondary))
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityHint("Opens Messages to \(AgentContact.formatted(model.agentNumber)) with the message filled in")
            if copied {
                Label("Copied. Paste it in Messages to \(AgentContact.formatted(model.agentNumber)).",
                      systemImage: "doc.on.clipboard")
                    .font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func send() {
        let wrapped = ForwardToKavach.wrap(message, from: from)
        guard let url = ForwardToKavach.messagesURL(number: model.agentNumber, message: message, from: from) else {
            UIPasteboard.general.string = wrapped; copied = true; return
        }
        openURL(url) { accepted in
            if !accepted { UIPasteboard.general.string = wrapped; copied = true }
        }
    }
}
