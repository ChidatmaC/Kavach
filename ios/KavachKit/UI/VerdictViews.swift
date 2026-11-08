import SwiftUI

/// Verdict badge: always color + icon + word, on the verdict's soft fill (text ≥7:1).
public struct VerdictBadge: View {
    let verdict: Verdict
    let large: Bool
    public init(_ verdict: Verdict, large: Bool = true) { self.verdict = verdict; self.large = large }

    public var body: some View {
        HStack(spacing: large ? Theme.Space.s : Theme.Space.xs) {
            Image(systemName: verdict.symbol).font(large ? .title2.weight(.semibold) : .subheadline.weight(.semibold))
            Text(verdict.word).font(large ? .title2.weight(.bold) : .subheadline.weight(.semibold))
        }
        .foregroundStyle(Theme.color(for: verdict))
        .padding(.vertical, large ? Theme.Space.s : 4)
        .padding(.horizontal, large ? Theme.Space.m : 10)
        .background(Theme.softColor(for: verdict), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.color(for: verdict).opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verdict: \(verdict.word)")
    }
}

/// Severity pill with an icon (only Critical is red).
public struct SeverityBadge: View {
    let severity: Severity
    public init(_ s: Severity) { severity = s }

    var symbol: String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .high, .medium: "exclamationmark.triangle.fill"
        case .low: "checkmark.circle.fill"
        case .unrated: "clock"
        }
    }

    public var body: some View {
        Label(severity.label, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 4).padding(.horizontal, 10)
            .foregroundStyle(Theme.color(for: severity))
            .background(Theme.softColor(for: severity), in: Capsule())
            .accessibilityElement(children: .ignore)
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

    /// Risky parts are bold, underlined and on the verdict's soft fill (not color alone).
    public static func attributed(_ text: String, phrases: [String], color: Color, fill: Color? = nil) -> AttributedString {
        var a = AttributedString(text)
        for r in ranges(in: text, phrases: phrases) {
            guard let lower = AttributedString.Index(r.lowerBound, within: a),
                  let upper = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lower..<upper].backgroundColor = fill ?? color.opacity(0.18)
            a[lower..<upper].foregroundColor = color
            a[lower..<upper].underlineStyle = .single
            a[lower..<upper].font = .body.weight(.bold)
        }
        return a
    }
}

/// Full result used by Check a message and the Share extension: verdict, one-sentence reason,
/// highlighted message, numbered "What to do".
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                VerdictBadge(result.verdict)
                Text(result.reason)
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Reason: \(result.reason)")
                if result.evidenceCount > 0 {
                    Label("\(result.evidenceCount) similar report\(result.evidenceCount == 1 ? "" : "s") from other people",
                          systemImage: "person.3")
                        .font(TypeScale.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !message.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("The message").font(TypeScale.overline).foregroundStyle(Theme.textSecondary)
                    Text(Highlighter.attributed(message, phrases: result.highlights, color: Theme.color(for: result.verdict),
                                                fill: Theme.softColor(for: result.verdict)))
                        .font(TypeScale.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Message with risky parts underlined: \(message)")
            }

            if !result.tips.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("What to do").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(result.tips.enumerated()), id: \.offset) { i, tip in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text("\(i + 1)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                                .frame(minWidth: 24, minHeight: 24)
                                .background(Theme.accentSoft, in: Circle())
                                .accessibilityHidden(true)
                            Text(tip).font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Step \(i + 1): \(tip)")
                    }
                }
            }
        }
        .onAppear { if prefs.autoSpeak { Speaker.shared.speak(spokenText) } }
    }
}

/// Quiet "Was this right?" row under every verdict. Sends `/app/feedback` in the background and
/// never blocks: the thank-you shows immediately, failures are ignored (it is a training signal).
public struct VerdictFeedbackControl: View {
    let verdict: Verdict
    let send: @Sendable (VerdictFeedback) async -> Void
    @State private var sent: VerdictFeedback.Choice?

    public init(verdict: Verdict, send: @escaping @Sendable (VerdictFeedback) async -> Void) {
        self.verdict = verdict
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let sent {
                Label(sent == .right ? "Thanks. Glad it helped." : "Thanks. This helps us get better.",
                      systemImage: "checkmark.circle")
                    .font(TypeScale.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Text("Was this right?").font(TypeScale.callout.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                FlowLayout(spacing: Theme.Space.xs) { buttons }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Feedback")
    }

    @ViewBuilder private var buttons: some View {
        choice(.right, title: "Yes", systemImage: "hand.thumbsup")
        choice(.wasScam, title: "This was a scam", systemImage: "xmark.octagon")
        choice(.wasSafe, title: "This was safe", systemImage: "checkmark.shield")
    }

    private func choice(_ c: VerdictFeedback.Choice, title: String, systemImage: String) -> some View {
        Button {
            sent = c
            let fb = VerdictFeedback(verdict: verdict, choice: c)
            Task.detached { await send(fb) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(TypeScale.callout.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: Theme.minTarget)
                .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(c == .right ? "Yes, this was right" : title)
    }
}
