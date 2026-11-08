import Foundation

/// "Forward to Kavach by text". iMessage forwarding can't carry metadata, so the app wraps the
/// message in the one format the agent treats as "a message I received, please scam-check it":
///
///     Forwarded message:
///     From: <name or number>        (optional, only when known)
///     “<the message they received>”
///
/// The message sits inside curly quotes, so straight quotes inside it never end it early.
public enum ForwardToKavach {
    public static let header = "Forwarded message:"
    public static let openQuote = "\u{201C}"   // “
    public static let closeQuote = "\u{201D}"  // ”

    /// The wrapped body. `from` is added as the second line when it isn't empty.
    public static func wrap(_ message: String, from: String? = nil) -> String {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [header]
        if let from = from?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty {
            lines.append("From: \(from)")
        }
        lines.append(openQuote + body + closeQuote)
        return lines.joined(separator: "\n")
    }

    /// `sms:<number>&body=<wrapped, percent-encoded>` (opens Messages with the body filled in).
    public static func messagesURL(number: String, message: String, from: String? = nil) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 8 else { return nil }
        return URL(string: "sms:\(digits)&body=\(encode(wrap(message, from: from)))")
    }

    /// Strict percent-encoding (only unreserved characters stay), so `&`, `=`, `#`, `+` and newlines
    /// inside the message survive.
    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // Only ASCII alphanumerics: CharacterSet.alphanumerics includes other scripts, which must be encoded.
        allowed = allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// One-sentence help for Settings.
    public static func helpText(appName: String = "Kavach") -> String {
        "When you forward a message, start it with \(header) so \(appName) knows you received it."
    }
}
