import SwiftUI
import UIKit

/// Kavach design system ("Accessible & Ethical" + Swiss minimalism, trust-blue product profile).
///
/// - One accent (trust blue). Green, amber and red are *status* colors only: red means "Likely scam"
///   or Critical and nothing else.
/// - Text pairs are measured for 7:1 (WCAG AAA) on their surfaces in light and dark mode; status text
///   on its soft fill stays at or above 7:1 as well.
/// - Typography is SF Pro through Dynamic Type text styles only (no fixed point sizes for text).
/// - Flat surfaces separated by hairlines, not shadows or blur. Motion is short and switched off
///   when Reduce Motion is on.
public enum Theme {
    // MARK: Color tokens (light / dark, with an Increase Contrast variant where it matters)

    /// The single accent: trust blue. Links, selection, primary buttons, the "You" node.
    public static let accent = dynamic(light: 0x1F4E8C, dark: 0x8DB8F2, lightHC: 0x163B6B, darkHC: 0xB5D2F8)
    /// Fill for primary buttons; `onAccent` is its text color.
    public static let accentFill = dynamic(light: 0x1F4E8C, dark: 0xA8C8F5, lightHC: 0x163B6B, darkHC: 0xC6DCFA)
    public static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0A1A33)
    public static let accentSoft = dynamic(light: 0xE5EDF8, dark: 0x142235)

    /// Screen background (grouped).
    public static let background = dynamic(light: 0xF4F6F9, dark: 0x0B0E13, lightHC: 0xEEF1F5, darkHC: 0x000000)
    /// Cards, rows, sheets.
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x161A21, lightHC: 0xFFFFFF, darkHC: 0x12161C)
    /// Inset areas inside a card (message quote, text editor).
    public static let surfaceSunken = dynamic(light: 0xEEF1F5, dark: 0x1E232B, lightHC: 0xE6EAF0, darkHC: 0x1B2028)

    /// ≈18:1 light, ≈16:1 dark.
    public static let textPrimary = dynamic(light: 0x0B1220, dark: 0xF3F5F8, lightHC: 0x000000, darkHC: 0xFFFFFF)
    /// ≈9:1 on surface in both modes (still above the 7:1 target).
    public static let textSecondary = dynamic(light: 0x3D4757, dark: 0xB4BDCA, lightHC: 0x262F3C, darkHC: 0xD3D9E2)

    /// Hairline separators and card borders (non-text, decorative).
    public static let separator = dynamic(light: 0xD5DBE3, dark: 0x2A303A, lightHC: 0x5B6575, darkHC: 0x8A94A3)
    /// Borders that carry meaning (selected answer, focus) — ≥3:1 against the surface.
    public static let borderStrong = dynamic(light: 0x5B6575, dark: 0x8A94A3, lightHC: 0x0B1220, darkHC: 0xF3F5F8)

    /// Status: protective / done. Text ≥7:1 on surface and on `safeSoft`.
    public static let safe = dynamic(light: 0x145A33, dark: 0x6FD39A, lightHC: 0x0E4426, darkHC: 0x8FE2B2)
    public static let safeSoft = dynamic(light: 0xE6F3EC, dark: 0x12261B)
    /// Status: caution / waiting / paused.
    public static let caution = dynamic(light: 0x6E4300, dark: 0xF2B544, lightHC: 0x543300, darkHC: 0xF7CC77)
    public static let cautionSoft = dynamic(light: 0xFBF1DC, dark: 0x2B2210)
    /// Status: "Likely scam" and Critical only.
    public static let danger = dynamic(light: 0x8E1B17, dark: 0xFF8A80, lightHC: 0x6E120F, darkHC: 0xFFADA6)
    public static let dangerSoft = dynamic(light: 0xFBE7E5, dark: 0x2E1514)
    public static let onDanger = dynamic(light: 0xFFFFFF, dark: 0x2A0705)

    /// Kept for source compatibility: the older code called the caution color "amber".
    public static var amber: Color { caution }

    /// Verdict colors: green / amber / red, always shown with an icon and a word.
    public static func color(for v: Verdict) -> Color {
        switch v {
        case .safe: safe
        case .suspicious: caution
        case .likelyScam: danger
        }
    }

    public static func softColor(for v: Verdict) -> Color {
        switch v {
        case .safe: safeSoft
        case .suspicious: cautionSoft
        case .likelyScam: dangerSoft
        }
    }

    /// Severity colors: only Critical is red.
    public static func color(for s: Severity) -> Color {
        switch s {
        case .critical: danger
        case .high, .medium: caution
        case .low: safe
        case .unrated: textSecondary
        }
    }

    public static func softColor(for s: Severity) -> Color {
        switch s {
        case .critical: dangerSoft
        case .high, .medium: cautionSoft
        case .low: safeSoft
        case .unrated: surfaceSunken
        }
    }

    // MARK: Layout tokens

    /// Minimum touch target (Apple HIG).
    public static let minTarget: CGFloat = 44

    /// 4-pt spacing scale.
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    /// Corner radii (continuous corners).
    public enum Radius {
        public static let s: CGFloat = 10
        public static let m: CGFloat = 14
        public static let l: CGFloat = 20
    }

    /// Icon sizes for SF Symbols placed in fixed frames (glyphs themselves follow text styles).
    public enum Icon {
        public static let s: CGFloat = 28
        public static let m: CGFloat = 36
        public static let l: CGFloat = 44
    }

    /// Elevation: flat by default; one hairline level; one level for floating content (sheets).
    public enum Elevation: Sendable { case flat, raised }

    // MARK: Motion tokens

    public enum Motion {
        /// Press feedback, toggles.
        public static let quick: Double = 0.15
        /// Content changes inside a screen.
        public static let standard: Double = 0.25
        /// Larger state changes (banner in/out).
        public static let emphasized: Double = 0.35

        /// An animation, or none when Reduce Motion is on.
        public static func animation(_ duration: Double = standard, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: duration)
        }
    }

    // MARK: Helpers

    static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            switch (traits.userInterfaceStyle == .dark, high) {
            case (true, true): return UIColor(hex: darkHC ?? dark)
            case (true, false): return UIColor(hex: dark)
            case (false, true): return UIColor(hex: lightHC ?? light)
            case (false, false): return UIColor(hex: light)
            }
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Type scale: SF Pro text styles only, so Dynamic Type always applies.
public enum TypeScale {
    /// Screen hero text (verdict word, "Act now").
    public static let display = Font.largeTitle.weight(.bold)
    /// Section titles.
    public static let title = Font.title2.weight(.semibold)
    /// Card titles, button labels.
    public static let headline = Font.headline
    public static let body = Font.body
    /// Secondary lines in cards.
    public static let callout = Font.callout
    public static let footnote = Font.footnote
    /// Section headers above groups.
    public static let overline = Font.subheadline.weight(.semibold)
    /// KPI numbers (tabular, so values don't jump while polling).
    public static let metric = Font.title.weight(.semibold).monospacedDigit()
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

    /// Screen background token.
    func kavachScreenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

struct LargerTextModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.dynamicTypeSize(.xxLarge ... .accessibility5) } else { content }
    }
}
