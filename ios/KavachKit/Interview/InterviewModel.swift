import Foundation

/// The five interview questions. Ids and answer values are exactly the wire values in
/// docs/CONTRACTS.md section 2 (`save_answer`). Severity is computed only in the module (D2).
public struct InterviewOption: Sendable, Hashable, Identifiable {
    public let value: String
    public let label: String
    public let symbol: String
    public var id: String { value }
}

public enum InterviewKind: Sendable, Hashable {
    /// Free text with quick-pick suggestions (q_identity).
    case text(suggestions: [String])
    case single([InterviewOption])
    /// Multi-select; `exclusive` clears the others and is cleared by them (q_shared "nothing").
    case multi([InterviewOption], exclusive: String)
}

public struct InterviewQuestion: Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: String
    public let kind: InterviewKind
}

public enum InterviewScript {
    /// Asked first for reports about a call (in-app Report a call, Recents): "no" ends the interview,
    /// and the module sets the level to Low right away (missed or declined call).
    public static let answeredQuestion = InterviewQuestion(id: "q_answered", prompt: "Did you answer the call?", kind: .single([
        InterviewOption(value: "yes", label: "Yes, I answered", symbol: "phone.fill"),
        InterviewOption(value: "no", label: "No, I missed it or declined", symbol: "phone.down.fill"),
    ]))

    /// The questions for one interview: call reports start with "Did you answer the call?".
    public static func questions(askAnswered: Bool) -> [InterviewQuestion] {
        askAnswered ? [answeredQuestion] + questions : questions
    }

    /// Every question id the app may save, in contract order (summary screen, replay order).
    public static let allQuestionIds = questions(askAnswered: true).map(\.id)

    /// True when this answer ends the interview early: the person didn't answer the call.
    public static func endsInterview(questionId: String, answer: String) -> Bool {
        questionId == answeredQuestion.id && answer == "no"
    }

    /// Contract order for q_shared items.
    public static let sharedItems = ["code", "pin", "password", "card", "gift_card", "money",
                                     "remote_app", "personal_details", "link"]

    public static let questions: [InterviewQuestion] = [
        InterviewQuestion(id: "q_identity", prompt: "Who did they say they were?", kind: .text(suggestions: [
            "My bank", "My phone company", "Government or police", "A family member", "Tech support",
            "A company or store", "I don't know",
        ])),
        InterviewQuestion(id: "q_ask", prompt: "Did they ask you to pay, call them back, or share something?", kind: .single([
            InterviewOption(value: "no", label: "No", symbol: "hand.raised.fill"),
            InterviewOption(value: "yes", label: "Yes, they asked", symbol: "questionmark.bubble.fill"),
            InterviewOption(value: "agreed", label: "Yes, and I agreed to pay or call back", symbol: "phone.arrow.up.right.fill"),
        ])),
        InterviewQuestion(id: "q_shared", prompt: "Did you share or do any of these? Choose all that apply.", kind: .multi([
            InterviewOption(value: "code", label: "A code sent to my phone", symbol: "number"),
            InterviewOption(value: "pin", label: "A PIN", symbol: "lock.fill"),
            InterviewOption(value: "password", label: "A password", symbol: "key.fill"),
            InterviewOption(value: "card", label: "Card or bank details", symbol: "creditcard.fill"),
            InterviewOption(value: "gift_card", label: "Gift card numbers", symbol: "giftcard.fill"),
            InterviewOption(value: "money", label: "I sent money", symbol: "dollarsign.circle.fill"),
            InterviewOption(value: "remote_app", label: "I installed an app they asked for", symbol: "apps.iphone"),
            InterviewOption(value: "personal_details", label: "Personal details, like my Social Security number or birthday", symbol: "person.text.rectangle.fill"),
            InterviewOption(value: "link", label: "I tapped a link they sent", symbol: "link"),
            InterviewOption(value: "nothing", label: "Nothing. I didn't share anything", symbol: "checkmark.shield.fill"),
        ], exclusive: "nothing")),
        InterviewQuestion(id: "q_secrecy", prompt: "Did they tell you to keep it secret or to hurry?", kind: .single([
            InterviewOption(value: "no", label: "No", symbol: "hand.thumbsup.fill"),
            InterviewOption(value: "yes", label: "Yes", symbol: "exclamationmark.bubble.fill"),
        ])),
        InterviewQuestion(id: "q_help", prompt: "Would you like your family to help?", kind: .single([
            InterviewOption(value: "yes", label: "Yes, please", symbol: "person.2.fill"),
            InterviewOption(value: "no", label: "Not right now", symbol: "person.fill"),
        ])),
    ]

    /// Toggles an option in a multi-select, enforcing the exclusive "nothing" choice.
    public static func toggle(_ value: String, in selection: Set<String>, exclusive: String = "nothing") -> Set<String> {
        var s = selection
        if s.contains(value) { s.remove(value); return s }
        if value == exclusive { return [exclusive] }
        s.remove(exclusive)
        s.insert(value)
        return s
    }

    /// Wire answer for q_shared: comma list in contract order, or "nothing". Empty selection → nil.
    public static func sharedAnswer(_ selection: Set<String>) -> String? {
        if selection.contains("nothing") { return "nothing" }
        let items = sharedItems.filter(selection.contains)
        return items.isEmpty ? nil : items.joined(separator: ",")
    }

    /// Wire answer for q_identity: trimmed free text (the module redacts and truncates).
    public static func identityAnswer(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(80))
    }

    /// "Question 2 of 5" for the five core questions; "About the call" for "Did you answer the call?",
    /// which comes before them and isn't counted.
    public static func progressLabel(for q: InterviewQuestion) -> String {
        guard let i = questions.firstIndex(where: { $0.id == q.id }) else { return "About the call" }
        return "Question \(i + 1) of \(questions.count)"
    }

    /// Text read aloud for a question (speaker icon / Accessibility Mode).
    public static func spoken(_ q: InterviewQuestion, index: Int) -> String {
        spoken(q)
    }

    public static func spoken(_ q: InterviewQuestion) -> String {
        var parts = [progressLabel(for: q) + ".", q.prompt]
        switch q.kind {
        case .text: parts.append("Tap an answer or type it.")
        case .single(let opts), .multi(let opts, _): parts.append(opts.map(\.label).joined(separator: ". "))
        }
        return parts.joined(separator: " ")
    }
}

/// The result after "Did you answer the call?" → "No, I missed it or declined".
public enum MissedCallCopy {
    public static let headline = "Good call not picking up"

    /// The number sentence only when a number was given (it's what goes to the community reports).
    public static func detail(numberGiven: Bool, appName: String = "Kavach") -> String {
        var parts = [String]()
        if numberGiven { parts.append("We've added this number to the community reports.") }
        parts.append("If they left a voicemail or texted you, forward it to \(appName).")
        return parts.joined(separator: " ")
    }
}
