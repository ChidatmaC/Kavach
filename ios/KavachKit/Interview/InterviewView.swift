import SwiftUI

/// One question per screen with "Question 1 of 5", large answers and a speaker icon.
/// Shared by the app (Companion, I need help, Report and block) and the Report extension.
public struct InterviewView: View {
    public typealias Save = @MainActor (_ questionId: String, _ answer: String) async throws -> Void

    let title: String
    let save: Save
    let onDone: @MainActor () -> Void

    @Environment(\.displayPreferences) private var prefs
    @State private var index = 0
    @State private var text = ""
    @State private var multi: Set<String> = []
    @State private var saving = false
    @State private var error: String?

    public init(title: String = "Tell us what happened", save: @escaping Save, onDone: @escaping @MainActor () -> Void) {
        self.title = title
        self.save = save
        self.onDone = onDone
    }

    private var questions: [InterviewQuestion] { InterviewScript.questions }
    private var question: InterviewQuestion { questions[min(index, questions.count - 1)] }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Question \(index + 1) of \(questions.count)")
                        .font(.headline).foregroundStyle(.secondary)
                        .accessibilityLabel("Question \(index + 1) of \(questions.count)")
                    Spacer()
                    Button {
                        Speaker.shared.speak(InterviewScript.spoken(question, index: index))
                    } label: {
                        Image(systemName: "speaker.wave.2.fill").font(.title2)
                            .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                    }
                    .accessibilityLabel("Read the question aloud")
                }
                ProgressView(value: Double(index + 1), total: Double(questions.count))
                    .accessibilityHidden(true)
                Text(question.prompt)
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                answers

                if let error {
                    Text(error).foregroundStyle(Theme.amber).font(.callout)
                        .accessibilityLabel("Problem: \(error)")
                }
                if saving { ProgressView("Saving…") }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .onChange(of: index, initial: true) { _, _ in
            if prefs.autoSpeak { Speaker.shared.speak(InterviewScript.spoken(question, index: index)) }
        }
    }

    @ViewBuilder private var answers: some View {
        switch question.kind {
        case .text(let suggestions):
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    answerButton(s, symbol: "person.fill.questionmark", selected: false) { submit(s) }
                }
                TextField("Something else (type it)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(minHeight: Theme.minTarget)
                    .submitLabel(.next)
                    .onSubmit { if let a = InterviewScript.identityAnswer(text) { submit(a) } }
                    .accessibilityLabel("Type who they said they were")
                Button("Next") { if let a = InterviewScript.identityAnswer(text) { submit(a) } }
                    .buttonStyle(KavachButtonStyle(prominent: true))
                    .disabled(InterviewScript.identityAnswer(text) == nil)
            }
        case .single(let options):
            VStack(spacing: 10) {
                ForEach(options) { o in
                    answerButton(o.label, symbol: o.symbol, selected: false) { submit(o.value) }
                }
            }
        case .multi(let options, let exclusive):
            VStack(spacing: 10) {
                ForEach(options) { o in
                    answerButton(o.label, symbol: o.symbol, selected: multi.contains(o.value)) {
                        multi = InterviewScript.toggle(o.value, in: multi, exclusive: exclusive)
                    }
                    .accessibilityAddTraits(multi.contains(o.value) ? .isSelected : [])
                }
                Button("Continue") { if let a = InterviewScript.sharedAnswer(multi) { submit(a) } }
                    .buttonStyle(KavachButtonStyle(prominent: true))
                    .disabled(InterviewScript.sharedAnswer(multi) == nil)
                    .accessibilityHint("Saves your choices")
            }
        }
    }

    private func answerButton(_ label: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        AnswerButton(label: label, symbol: symbol, selected: selected, action: action)
    }

    private func submit(_ answer: String) {
        let qid = question.id
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await save(qid, answer)
                text = ""
                multi = []
                if index + 1 < questions.count { index += 1 } else { onDone() }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct AnswerButton: View {
    let label: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.displayPreferences) private var prefs
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .font(.title2).frame(width: 36).accessibilityHidden(true)
                Text(label).font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, prefs.accessibilityMode ? 20 : 14)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Theme.accent : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(prefs.highContrast ? Color.primary : Theme.accent.opacity(0.4), lineWidth: prefs.highContrast ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: taps) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityLabel(label)
    }
}
