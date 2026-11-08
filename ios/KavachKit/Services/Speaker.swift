import AVFoundation
import Observation

/// Reads verdicts, steps and questions aloud. Keeps the last utterance for the Repeat button.
@MainActor @Observable
public final class Speaker {
    public static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    public private(set) var lastText: String = ""

    public init() {}

    public func speak(_ text: String) {
        guard !text.isEmpty else { return }
        lastText = text
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        u.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier == "en" ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : "en-US")
        synth.speak(u)
    }

    public func repeatLast() { speak(lastText) }
    public func stop() { synth.stopSpeaking(at: .immediate) }
}
