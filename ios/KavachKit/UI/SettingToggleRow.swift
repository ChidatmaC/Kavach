import SwiftUI

public extension Theme {
    /// Status colors: green when protective, amber when something is paused, grey when simply off.
    static func color(for tone: SettingToggle.Tone) -> Color {
        switch tone {
        case .on: safe
        case .attention: caution
        case .off: textSecondary
        }
    }
}

/// A toggle with an icon and a status line that both follow its value, e.g. "Family alerts paused"
/// with a bell-slash in amber vs "Family alerts on" with a bell in green. ≥ 44 pt, Dynamic Type,
/// one VoiceOver element ("Pause family alerts, Family alerts paused, on").
public struct SettingToggleRow: View {
    let setting: SettingToggle
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    @Environment(\.displayPreferences) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ setting: SettingToggle, title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.setting = setting
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    public var body: some View {
        let look = setting.appearance(isOn: isOn)
        let color = Theme.color(for: look.tone)
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: look.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: Theme.Icon.s)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text(look.status)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(prefs.highContrast ? Theme.textPrimary : color)
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .frame(minHeight: Theme.minTarget)
        .animation(Theme.Motion.animation(Theme.Motion.quick, reduceMotion: reduceMotion), value: isOn)
        .sensoryFeedback(.selection, trigger: isOn) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityIdentifier("toggle.\(setting.rawValue)")
    }
}
