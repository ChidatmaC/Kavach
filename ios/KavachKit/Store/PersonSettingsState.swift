import Foundation
import Observation

/// Every on/off setting the app shows with an icon and a status line.
/// The first three live on `person` in SpacetimeDB; the last two are device-local display preferences.
public enum SettingToggle: String, CaseIterable, Sendable {
    case sharingPaused, accessibilityMode, criticalOverridesPause
    case spokenVerdicts, largerText

    /// The `person` column this toggle mirrors (nil for device-local preferences).
    public var personKeyPath: WritableKeyPath<Person, Bool>? {
        switch self {
        case .sharingPaused: \.sharingPaused
        case .accessibilityMode: \.accessibilityMode
        case .criticalOverridesPause: \.criticalOverridesPause
        case .spokenVerdicts, .largerText: nil
        }
    }

    public enum Tone: Sendable, Equatable { case on, off, attention }

    public struct Appearance: Sendable, Equatable {
        public let systemImage: String
        public let status: String
        public let tone: Tone
    }

    /// Icon, status text and tone for the current value. Each state has a different icon, not just a
    /// different color, so the change is visible without color vision.
    public func appearance(isOn: Bool) -> Appearance {
        switch (self, isOn) {
        case (.sharingPaused, true): Appearance(systemImage: "bell.slash.fill", status: "Family alerts paused", tone: .attention)
        case (.sharingPaused, false): Appearance(systemImage: "bell.fill", status: "Family alerts on", tone: .on)
        case (.accessibilityMode, true): Appearance(systemImage: "accessibility.fill", status: "Accessibility Mode on", tone: .on)
        case (.accessibilityMode, false): Appearance(systemImage: "accessibility", status: "Accessibility Mode off", tone: .off)
        case (.criticalOverridesPause, true): Appearance(systemImage: "bell.badge.fill", status: "Emergencies always reach them", tone: .on)
        case (.criticalOverridesPause, false): Appearance(systemImage: "bell.badge.slash", status: "Emergencies follow your pause", tone: .off)
        case (.spokenVerdicts, true): Appearance(systemImage: "speaker.wave.2.fill", status: "Results read aloud", tone: .on)
        case (.spokenVerdicts, false): Appearance(systemImage: "speaker.slash.fill", status: "Results not read aloud", tone: .off)
        case (.largerText, true): Appearance(systemImage: "textformat.size.larger", status: "Larger text on", tone: .on)
        case (.largerText, false): Appearance(systemImage: "textformat.size", status: "Larger text off", tone: .off)
        }
    }
}

/// The person row as the app shows it: the last polled `my_person` with in-flight toggle changes laid
/// on top (optimistic update). A failed write drops its overlay, which reverts the toggle. Polls that
/// started before a write finished are ignored, so a stale poll can't flip a toggle back.
@MainActor
@Observable
public final class PersonSettingsState {
    /// What the UI reads. Changes immediately when a toggle is flipped and whenever a poll brings news
    /// (e.g. the person texted "pause" to the agent).
    public private(set) var person: Person?
    public private(set) var lastError: String?

    @ObservationIgnored private var server: Person?
    @ObservationIgnored private var pending: [SettingToggle: (value: Bool, write: Int)] = [:]
    @ObservationIgnored private var writeCounter = 0
    @ObservationIgnored private var fetchCounter = 0
    @ObservationIgnored private var acceptFetchesFrom = 0

    public init(person: Person? = nil) {
        server = person
        self.person = person
    }

    public func isPending(_ setting: SettingToggle) -> Bool { pending[setting] != nil }

    /// Call before starting a `my_person` poll; pass the result to `receive(_:fetch:)`.
    public func beginFetch() -> Int {
        fetchCounter += 1
        return fetchCounter
    }

    /// A polled `my_person` row. Ignored when the poll started before the last local write settled.
    public func receive(_ polled: Person?, fetch: Int) {
        guard fetch >= acceptFetchesFrom else { return }
        server = polled
        recompute()
    }

    /// Sign-in (register) or sign-out: take this row as the truth and forget pending changes.
    public func replace(_ p: Person?) {
        server = p
        pending = [:]
        acceptFetchesFrom = fetchCounter + 1
        recompute()
    }

    /// A non-toggle change (code word, APNs token) that the server accepted.
    public func commit(_ p: Person) {
        server = p
        acceptFetchesFrom = fetchCounter + 1
        recompute()
    }

    /// Flips a person setting: shows the new value at once, writes it with `write` (which receives the
    /// person with every in-flight change applied), and reverts it if the write throws.
    @discardableResult
    public func set(_ setting: SettingToggle, to value: Bool,
                    write: (Person) async throws -> Void) async -> Bool {
        guard setting.personKeyPath != nil, person != nil else { return false }
        writeCounter += 1
        let id = writeCounter
        pending[setting] = (value, id)
        recompute()
        guard let target = person else { return false }
        do {
            try await write(target)
            if pending[setting]?.write == id {
                pending[setting] = nil
                if let kp = setting.personKeyPath { server?[keyPath: kp] = value }
            }
            lastError = nil
            acceptFetchesFrom = fetchCounter + 1
            recompute()
            return true
        } catch {
            if pending[setting]?.write == id { pending[setting] = nil }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            acceptFetchesFrom = fetchCounter + 1
            recompute()
            return false
        }
    }

    public func clearError() { lastError = nil }

    private func recompute() {
        var p = server
        if p != nil {
            for (setting, change) in pending {
                if let kp = setting.personKeyPath { p![keyPath: kp] = change.value }
            }
        }
        if person != p { person = p }
    }
}
