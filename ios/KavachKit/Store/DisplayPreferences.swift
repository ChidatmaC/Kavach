import Foundation

/// Presentation settings. Accessibility Mode (D12, off by default) changes presentation only and
/// never removes a feature. `accessibilityMode` mirrors `person.accessibility_mode`; the other two
/// are device-local toggles in Settings.
public struct DisplayPreferences: Sendable, Equatable {
    public var accessibilityMode: Bool = false
    public var spokenVerdicts: Bool = false
    public var largerText: Bool = false

    public init(accessibilityMode: Bool = false, spokenVerdicts: Bool = false, largerText: Bool = false) {
        self.accessibilityMode = accessibilityMode
        self.spokenVerdicts = spokenVerdicts
        self.largerText = largerText
    }

    /// Verdicts and steps are read aloud automatically (with a visible Repeat button).
    public var autoSpeak: Bool { accessibilityMode || spokenVerdicts }
    public var useLargerText: Bool { accessibilityMode || largerText }
    public var highContrast: Bool { accessibilityMode }
    public var hapticsOnEveryTap: Bool { accessibilityMode }
    /// Home shows only the three actions as full-width buttons; "This week" moves to its own tab.
    public var homeShowsOnlyActions: Bool { accessibilityMode }

    public static func load(from store: SharedStore = SharedStore()) -> DisplayPreferences {
        DisplayPreferences(accessibilityMode: store.bool(.accessibilityMode),
                           spokenVerdicts: store.bool(.spokenVerdicts),
                           largerText: store.bool(.largerText))
    }

    public func save(to store: SharedStore = SharedStore()) {
        store.set(accessibilityMode, .accessibilityMode)
        store.set(spokenVerdicts, .spokenVerdicts)
        store.set(largerText, .largerText)
    }
}
