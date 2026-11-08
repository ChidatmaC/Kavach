import Foundation

/// E.164 normalization for numbers typed by hand or picked from Contacts. US is the default region:
/// 10-digit numbers get +1. Handles formatting characters, "00"/"011" international prefixes and
/// trailing extensions. Returns nil when the result can't be a valid E.164 number (8–15 digits).
/// Display/input helper only; the module validates again.
public enum PhoneNumbers {
    public static func e164(_ raw: String, defaultCountryCode: String = "1") -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop an extension: "555-555-0101 ext. 12", "x12", ";12", ",12".
        if let r = s.range(of: #"(?i)(\s*(ext\.?|extension|x)\s*\d+|[;,].*)$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        let hasPlus = s.first == "+" || s.hasPrefix("\u{FF0B}")
        var digits = s.filter(\.isASCIIDigitLike).map { $0.asciiDigit }.joined()
        if digits.isEmpty { return nil }

        if hasPlus {
            // already international
        } else if digits.hasPrefix("011"), defaultCountryCode == "1" {
            digits.removeFirst(3)
        } else if digits.hasPrefix("00") {
            digits.removeFirst(2)
        } else if defaultCountryCode == "1" {
            if digits.count == 10 { digits = "1" + digits }
            else if digits.count == 11, digits.hasPrefix("1") { /* already has the country code */ }
            else { return nil }
        } else {
            if digits.hasPrefix("0") { digits.removeFirst() }
            digits = defaultCountryCode + digits
        }
        guard (8...15).contains(digits.count), digits.first != "0" else { return nil }
        return "+" + digits
    }

    /// "+1 (415) 610-6180" for US numbers; other numbers unchanged.
    public static func formatted(_ e164: String) -> String {
        let d = e164.filter(\.isNumber)
        guard d.count == 11, d.hasPrefix("1") else { return e164 }
        let a = Array(d)
        return "+1 (\(String(a[1...3]))) \(String(a[4...6]))-\(String(a[7...10]))"
    }
}

/// Back-compatible helper used across the app: E.164 or "" when the input isn't a usable number.
public func normalizePhone(_ raw: String) -> String {
    PhoneNumbers.e164(raw) ?? ""
}

private extension Character {
    /// ASCII digits plus full-width digits (pasted from some keyboards).
    var isASCIIDigitLike: Bool { ("0"..."9").contains(self) || ("\u{FF10}"..."\u{FF19}").contains(self) }
    var asciiDigit: String {
        if ("0"..."9").contains(self) { return String(self) }
        guard let v = unicodeScalars.first?.value else { return "" }
        return String(v - 0xFF10)
    }
}
