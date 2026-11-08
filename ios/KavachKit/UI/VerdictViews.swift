import SwiftUI

/// Verdict badge: always color + icon + word.
public struct VerdictBadge: View {
    let verdict: Verdict
    let large: Bool
    public init(_ verdict: Verdict, large: Bool = true) { self.verdict = verdict; self.large = large }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: verdict.symbol).font(large ? .title : .headline)
            Text(verdict.word).font(large ? .title2.weight(.bold) : .headline)
        }
        .foregroundStyle(.white)
        .padding(.vertical, large ? 12 : 6)
        .padding(.horizontal, large ? 18 : 10)
        .background(Theme.color(for: verdict), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verdict: \(verdict.word)")
    }
}

/// Severity pill (only Critical is red).
public struct SeverityBadge: View {
    let severity: Severity
    public init(_ s: Severity) { severity = s }
    public var body: some View {
        Text(severity.label)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 4).padding(.horizontal, 10)
            .foregroundStyle(severity == .unrated ? Color.primary : .white)
            .background(Theme.color(for: severity).opacity(severity == .unrated ? 0.2 : 1), in: Capsule())
            .accessibilityLabel("Level: \(severity.label)")
    }
}

/// Builds the highlighted message text: agent-provided phrases plus links and phone numbers found
/// on device (display only).
public enum Highlighter {
    public static func ranges(in text: String, phrases: [String]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for p in phrases where !p.isEmpty {
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: p, options: .caseInsensitive, range: search) {
                out.append(r)
                search = r.upperBound..<text.endIndex
            }
        }
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let ns = NSRange(text.startIndex..., in: text)
            for m in detector.matches(in: text, options: [], range: ns) {
                if let r = Range(m.range, in: text) { out.append(r) }
            }
        }
        return out
    }

    /// Links in the text (for "Report and block").
    public static func links(in text: String) -> [URL] {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return d.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }

    public static func attributed(_ text: String, phrases: [String], color: Color) -> AttributedString {
        var a = AttributedString(text)
        for r in ranges(in: text, phrases: phrases) {
            guard let lower = AttributedString.Index(r.lowerBound, within: a),
                  let upper = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lower..<upper].backgroundColor = color.opacity(0.25)
            a[lower..<upper].underlineStyle = .single
            a[lower..<upper].font = .body.weight(.bold)
        }
        return a
    }
}

/// Full result card used by Check a message and the Share extension.
public struct CheckResultView: View {
    let result: CheckResult
    let message: String
    @Environment(\.displayPreferences) private var prefs

    public init(result: CheckResult, message: String) { self.result = result; self.message = message }

    public var spokenText: String {
        ([result.verdict.word + ".", result.reason] + (result.tips.isEmpty ? [] : ["What to do:"] + result.tips))
            .joined(separator: " ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VerdictBadge(result.verdict)
            Text(result.reason).font(.title3)
                .accessibilityLabel("Reason: \(result.reason)")
            if !message.isEmpty {
                Text(Highlighter.attributed(message, phrases: result.highlights, color: Theme.color(for: result.verdict)))
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Message with risky parts highlighted: \(message)")
            }
            if !result.tips.isEmpty {
                Text("What to do").font(.headline)
                ForEach(Array(result.tips.enumerated()), id: \.offset) { i, tip in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1).").font(.headline).accessibilityHidden(true)
                        Text(tip)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(i + 1): \(tip)")
                }
            }
        }
        .onAppear { if prefs.autoSpeak { Speaker.shared.speak(spokenText) } }
    }
}
