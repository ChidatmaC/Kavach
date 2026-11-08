import AppIntents
import KavachKit
import UIKit

/// "Open Call Companion" — assign to the Action Button or Back Tap (via Shortcuts).
struct OpenCallCompanionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Call Companion"
    static let description = IntentDescription("Opens Call Companion full screen and lets your family know you asked for help.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.route = .companion
        return .result()
    }
}

/// "Check this with <app name>" — with text (from Shortcuts/share) it checks right away and speaks
/// the verdict; without text it opens Check a message.
struct CheckWithKavachIntent: AppIntent {
    static let title: LocalizedStringResource = "Check a Message"
    static let description = IntentDescription("Checks whether a message looks like a scam.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Message", description: "The message text to check", requestValueDialog: "What does the message say?")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let text, !text.isEmpty, let api = model.api else {
            try await continueInForeground()
            model.route = .check(prefill: text)
            return .result(dialog: "Paste or choose the message to check.")
        }
        let r = await api.check(text: text, source: .appPaste)
        return .result(dialog: "\(r.verdict.word). \(r.reason)")
    }
}

/// "I need help" — opens the help screen (steps, interview, call family).
struct NeedHelpIntent: AppIntent {
    static let title: LocalizedStringResource = "I Need Help"
    static let description = IntentDescription("Opens help: your next steps, a short interview, or a call to your family.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.route = .needHelp
        return .result()
    }
}

/// "Forward to Kavach": takes text (Shortcuts, or the share sheet via a shortcut) and opens Messages
/// to the agent with it wrapped as "Forwarded message: …", so the agent scam-checks it.
struct ForwardToKavachIntent: AppIntent {
    static let title: LocalizedStringResource = "Forward to Kavach"
    static let description = IntentDescription("Opens Messages with the text ready to send to the agent, marked as a message you received.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Message", description: "The message you received", requestValueDialog: "What does the message say?")
    var text: String

    @Parameter(title: "From", description: "Who sent it (name or number), if you know")
    var from: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let number = AppModel.shared.agentNumber
        let wrapped = ForwardToKavach.wrap(text, from: from)
        if let url = ForwardToKavach.messagesURL(number: number, message: text, from: from),
           await UIApplication.shared.open(url) {
            return .result(dialog: "Messages is open. Tap send.")
        }
        UIPasteboard.general.string = wrapped
        return .result(dialog: "Copied. Paste it in Messages to \(AgentContact.formatted(number)).")
    }
}

/// Siri phrases. `.applicationName` is the bundle display name, which comes from APP_DISPLAY_NAME,
/// so renaming the product renames every phrase.
struct KavachShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCallCompanionIntent(),
            phrases: [
                "Open Call Companion in \(.applicationName)",
                "Open \(.applicationName) Call Companion",
                "I'm on a scam call \(.applicationName)",
            ],
            shortTitle: "Call Companion",
            systemImageName: "phone.badge.waveform.fill"
        )
        AppShortcut(
            intent: CheckWithKavachIntent(),
            phrases: [
                "Check this with \(.applicationName)",
                "Is this a scam \(.applicationName)",
            ],
            shortTitle: "Check a Message",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: NeedHelpIntent(),
            phrases: [
                "I need help in \(.applicationName)",
                "\(.applicationName) I need help",
            ],
            shortTitle: "I Need Help",
            systemImageName: "hand.raised.fill"
        )
        AppShortcut(
            intent: ForwardToKavachIntent(),
            phrases: [
                "Forward to \(.applicationName)",
                "Forward this to \(.applicationName)",
            ],
            shortTitle: "Forward to Kavach",
            systemImageName: "arrowshape.turn.up.right"
        )
    }
}
