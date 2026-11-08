import SwiftUI

/// Calm style with one accent color. Red is reserved for "Likely scam" and Critical.
public enum Theme {
    /// The single accent (calm teal-blue).
    public static let accent = Color(red: 0.05, green: 0.42, blue: 0.55)
    public static let safe = Color(red: 0.10, green: 0.55, blue: 0.25)
    public static let amber = Color(red: 0.80, green: 0.50, blue: 0.00)
    public static let danger = Color(red: 0.78, green: 0.10, blue: 0.10)

    public static func color(for v: Verdict) -> Color {
        switch v {
        case .safe: safe
        case .suspicious: amber
        case .likelyScam: danger
        }
    }

    /// Severity colors: only Critical is red.
    public static func color(for s: Severity) -> Color {
        switch s {
        case .critical: danger
        case .high, .medium: amber
        case .low: safe
        case .unrated: .secondary
        }
    }

    public static let minTarget: CGFloat = 44
}

// MARK: Environment

private struct DisplayPreferencesKey: EnvironmentKey {
    static let defaultValue = DisplayPreferences()
}

public extension EnvironmentValues {
    var displayPreferences: DisplayPreferences {
        get { self[DisplayPreferencesKey.self] }
        set { self[DisplayPreferencesKey.self] = newValue }
    }
}

public extension View {
    /// Applies Accessibility Mode presentation: larger text and the preferences in the environment.
    func kavachDisplay(_ prefs: DisplayPreferences) -> some View {
        self
            .environment(\.displayPreferences, prefs)
            .modifier(LargerTextModifier(enabled: prefs.useLargerText))
            .tint(Theme.accent)
    }
}

struct LargerTextModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.dynamicTypeSize(.xxLarge ... .accessibility5) } else { content }
    }
}

// MARK: Buttons

/// Large, full-width action button (≥ 44 pt, Dynamic Type) with haptics in Accessibility Mode.
public struct BigActionButton: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    let tint: Color
    let action: () -> Void
    @Environment(\.displayPreferences) private var prefs
    @State private var taps = 0

    public init(_ title: String, systemImage: String, subtitle: String? = nil, tint: Color = Theme.accent,
                action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.subtitle = subtitle; self.tint = tint; self.action = action
    }

    public var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle, !prefs.homeShowsOnlyActions {
                        Text(subtitle).font(.subheadline).opacity(0.85)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.headline).accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.vertical, prefs.accessibilityMode ? 26 : 18)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
            .background(prefs.highContrast ? Color.black : tint, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if prefs.highContrast { RoundedRectangle(cornerRadius: 18).stroke(.white, lineWidth: 3) }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
    }
}

/// Bordered secondary button that keeps ≥ 44 pt and gives haptics in Accessibility Mode.
public struct KavachButtonStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color
    public init(prominent: Bool = false, tint: Color = Theme.accent) { self.prominent = prominent; self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent, tint: tint)
    }

    struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let tint: Color
        @Environment(\.displayPreferences) private var prefs
        var body: some View {
            configuration.label
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: prefs.accessibilityMode ? 60 : Theme.minTarget)
                .padding(.horizontal, 12)
                .foregroundStyle(prominent ? Color.white : tint)
                .background(prominent ? tint : tint.opacity(prefs.highContrast ? 0.25 : 0.12),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if prefs.highContrast { RoundedRectangle(cornerRadius: 14).stroke(tint, lineWidth: 2) }
                }
                .opacity(configuration.isPressed ? 0.7 : 1)
                .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, new in new && prefs.hapticsOnEveryTap }
        }
    }
}

/// "Repeat" button shown whenever something was read aloud automatically.
public struct RepeatSpeechButton: View {
    @Environment(\.displayPreferences) private var prefs
    public init() {}
    public var body: some View {
        if prefs.autoSpeak {
            Button {
                Speaker.shared.repeatLast()
            } label: {
                Label("Repeat", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(KavachButtonStyle())
            .accessibilityHint("Reads it out loud again")
        }
    }
}

/// A rounded card container.
public struct Card<Content: View>: View {
    let content: Content
    @Environment(\.displayPreferences) private var prefs
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                if prefs.highContrast { RoundedRectangle(cornerRadius: 16).stroke(Color.primary, lineWidth: 2) }
            }
    }
}
