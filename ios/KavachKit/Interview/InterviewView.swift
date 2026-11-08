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

    let questions: [InterviewQuestion]

    /// `startIndex` resumes an unfinished questionnaire at its first unanswered question (an index
    /// into `questions`). `askAnswered` starts call reports with "Did you answer the call?"; a "no"
    /// there ends the interview (`InterviewScript.endsInterview`).
    public init(title: String = "Tell us what happened", askAnswered: Bool = false, startIndex: Int = 0,
                save: @escaping Save, onDone: @escaping @MainActor () -> Void) {
        self.title = title
        self.save = save
        self.onDone = onDone
        let qs = InterviewScript.questions(askAnswered: askAnswered)
        questions = qs
        _index = State(initialValue: max(0, min(startIndex, qs.count - 1)))
    }

    private var question: InterviewQuestion { questions[min(index, questions.count - 1)] }
    /// Progress through the five core questions ("Did you answer the call?" isn't counted).
    private var coreProgress: Double {
        let core = InterviewScript.questions
        return Double((core.firstIndex { $0.id == question.id } ?? -1) + 1) / Double(core.count)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(alignment: .center) {
                        Text(InterviewScript.progressLabel(for: question))
                            .font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button {
                            Speaker.shared.speak(InterviewScript.spoken(question))
                        } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Read the question aloud")
                    }
                    ProgressView(value: coreProgress)
                        .tint(Theme.accent)
                        .accessibilityHidden(true)
                }
                Text(question.prompt)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                answers

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(TypeScale.callout).foregroundStyle(Theme.caution)
                        .accessibilityLabel("Problem: \(error)")
                }
                if saving { ProgressView("Saving…").tint(Theme.accent) }
            }
            .padding(Theme.Space.m)
        }
        .kavachScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .onChange(of: index, initial: true) { _, _ in
            if prefs.autoSpeak { Speaker.shared.speak(InterviewScript.spoken(question)) }
        }
    }

    @ViewBuilder private var answers: some View {
        switch question.kind {
        case .text(let suggestions):
            VStack(spacing: Theme.Space.s) {
                ForEach(suggestions, id: \.self) { s in
                    answerButton(s, symbol: "person.crop.circle.badge.questionmark", selected: false) { submit(s) }
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Something else").font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                    TextField("Type who they said they were", text: $text)
                        .font(.title3)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: 52)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                            .strokeBorder(Theme.borderStrong, lineWidth: 1))
                        .submitLabel(.next)
                        .onSubmit { if let a = InterviewScript.identityAnswer(text) { submit(a) } }
                        .accessibilityLabel("Type who they said they were")
                }
                .padding(.top, Theme.Space.xs)
                Button("Next") { if let a = InterviewScript.identityAnswer(text) { submit(a) } }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .disabled(InterviewScript.identityAnswer(text) == nil)
            }
        case .single(let options):
            VStack(spacing: Theme.Space.s) {
                ForEach(options) { o in
                    answerButton(o.label, symbol: o.symbol, selected: false) { submit(o.value) }
                }
            }
        case .multi(let options, let exclusive):
            VStack(spacing: Theme.Space.s) {
                ForEach(options) { o in
                    answerButton(o.label, symbol: o.symbol, selected: multi.contains(o.value)) {
                        multi = InterviewScript.toggle(o.value, in: multi, exclusive: exclusive)
                    }
                    .accessibilityAddTraits(multi.contains(o.value) ? .isSelected : [])
                }
                Button("Continue") { if let a = InterviewScript.sharedAnswer(multi) { submit(a) } }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .padding(.top, Theme.Space.xs)
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
                if InterviewScript.endsInterview(questionId: qid, answer: answer) || index + 1 >= questions.count {
                    onDone()
                } else {
                    index += 1
                }
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
            HStack(spacing: Theme.Space.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Theme.Icon.s)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, prefs.accessibilityMode ? Theme.Space.l : Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? Theme.accentSoft : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : (prefs.highContrast ? Theme.borderStrong : Theme.separator),
                                  lineWidth: selected || prefs.highContrast ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.selection, trigger: taps) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityLabel(label)
    }
}
