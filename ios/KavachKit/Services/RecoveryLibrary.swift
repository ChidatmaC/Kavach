import Foundation

/// Vetted recovery step wording (D10). The build copies `shared/recovery_library.yaml` into the
/// KavachKit bundle unchanged; this reads its `steps:` section (key → priority, text).
public struct RecoveryLibrary: Sendable {
    public struct Step: Sendable, Equatable { public let priority: String; public let text: String }
    public let steps: [String: Step]

    public static let shared: RecoveryLibrary = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "recovery_library", withExtension: "yaml"),
              let yaml = try? String(contentsOf: url, encoding: .utf8)
        else { return RecoveryLibrary(steps: [:]) }
        return RecoveryLibrary(yaml: yaml)
    }()

    public init(steps: [String: Step]) { self.steps = steps }

    /// Minimal parser for the library's fixed shape:
    /// ```
    /// steps:
    ///   key:
    ///     priority: now
    ///     text: Sentence.
    /// ```
    public init(yaml: String) {
        var result: [String: Step] = [:]
        var inSteps = false
        var key: String?
        var priority = ""
        var text = ""
        func flush() {
            if let k = key, !text.isEmpty { result[k] = Step(priority: priority, text: text) }
            key = nil; priority = ""; text = ""
        }
        for raw in yaml.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") || raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                flush()
                inSteps = line == "steps:"
                continue
            }
            guard inSteps else { continue }
            if indent == 2, line.hasSuffix(":") {
                flush()
                key = String(line.dropLast())
            } else if indent >= 4, let colon = line.firstIndex(of: ":") {
                let field = line[..<colon]
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                    value = String(value.dropFirst().dropLast())
                }
                if field == "priority" { priority = value } else if field == "text" { text = value }
            }
        }
        flush()
        steps = result
    }

    /// Wording for a step key, or a safe generic line if the key is unknown.
    public func text(for key: String) -> String {
        steps[key]?.text ?? "Follow the advice from your bank or a trusted person for this step."
    }
}

final class BundleToken {}
