import SwiftUI
import UIKit

/// Semantic tone for banners, pills and icons. Each tone has a strong color (text/icon, ≥7:1 on its
/// soft fill) and a soft fill. Danger is reserved for "Likely scam" and Critical.
public enum StatusTone: Sendable, Equatable {
    case info, success, caution, danger, neutral

    public var color: Color {
        switch self {
        case .info: Theme.accent
        case .success: Theme.safe
        case .caution: Theme.caution
        case .danger: Theme.danger
        case .neutral: Theme.textSecondary
        }
    }

    public var soft: Color {
        switch self {
        case .info: Theme.accentSoft
        case .success: Theme.safeSoft
        case .caution: Theme.cautionSoft
        case .danger: Theme.dangerSoft
        case .neutral: Theme.surfaceSunken
        }
    }
}

// MARK: Surfaces

/// Flat card: surface fill, hairline border, 16-pt padding. Accessibility Mode draws a strong border.
public struct Card<Content: View>: View {
    let padding: CGFloat
    let content: Content
    @Environment(\.displayPreferences) private var prefs

    public init(padding: CGFloat = Theme.Space.m, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(prefs.highContrast ? Theme.borderStrong : Theme.separator,
                                  lineWidth: prefs.highContrast ? 2 : 1)
            }
    }
}

/// Section title above a group of cards (a VoiceOver heading).
public struct SectionTitle: View {
    let title: String
    let detail: String?
    public init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TypeScale.title).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.xs)
    }
}

/// Symbol on a soft rounded square. Decorative by default (hidden from VoiceOver).
public struct IconTile: View {
    let systemImage: String
    let tone: StatusTone
    let size: CGFloat
    public init(_ systemImage: String, tone: StatusTone = .info, size: CGFloat = Theme.Icon.m) {
        self.systemImage = systemImage; self.tone = tone; self.size = size
    }
    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(tone.soft, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Small status label: icon + word, never color alone.
public struct StatusPill: View {
    let text: String
    let systemImage: String
    let tone: StatusTone
    public init(_ text: String, systemImage: String, tone: StatusTone) {
        self.text = text; self.systemImage = systemImage; self.tone = tone
    }
    public var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(tone.soft, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Calm, full-width message with an icon, a title, optional text and optional actions.
public struct StatusBanner<Actions: View>: View {
    let tone: StatusTone
    let systemImage: String
    let title: String
    let message: String?
    let actions: Actions
    @Environment(\.displayPreferences) private var prefs

    public init(tone: StatusTone, systemImage: String, title: String, message: String? = nil,
                @ViewBuilder actions: () -> Actions) {
        self.tone = tone; self.systemImage = systemImage; self.title = title; self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(TypeScale.headline).foregroundStyle(tone == .neutral ? Theme.textPrimary : tone.color)
                    if let message {
                        Text(message).font(TypeScale.body).foregroundStyle(Theme.textPrimary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            actions
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.soft, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(prefs.highContrast ? tone.color : tone.color.opacity(0.35), lineWidth: prefs.highContrast ? 2 : 1)
        }
    }
}

public extension StatusBanner where Actions == EmptyView {
    init(tone: StatusTone, systemImage: String, title: String, message: String? = nil) {
        self.init(tone: tone, systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Key number with a label (dashboard).
public struct KPITile: View {
    let value: String
    let label: String
    let detail: String?
    let systemImage: String
    let tone: StatusTone

    public init(value: String, label: String, detail: String? = nil, systemImage: String, tone: StatusTone = .info) {
        self.value = value; self.label = label; self.detail = detail; self.systemImage = systemImage; self.tone = tone
    }

    public var body: some View {
        Card(padding: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(TypeScale.metric).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: Theme.Space.xs)
                Image(systemName: systemImage).font(.headline).foregroundStyle(tone.color)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(detail.map { ". \($0)" } ?? "")")
    }
}

// MARK: Buttons

/// Button roles: one primary per screen, secondary for the rest, destructive (red) only for
/// "Likely scam"/Critical actions, quiet for low-emphasis text actions. ≥44 pt, pressed state by
/// opacity (no layout shift), haptics in Accessibility Mode.
public struct KavachButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, destructive, quiet }
    let kind: Kind
    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.displayPreferences) private var prefs
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(TypeScale.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: kind == .quiet ? nil : .infinity, minHeight: prefs.accessibilityMode ? 56 : Theme.minTarget)
                .padding(.horizontal, Theme.Space.m)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay {
                    if kind == .secondary || (prefs.highContrast && kind != .quiet) {
                        RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                            .strokeBorder(prefs.highContrast ? Theme.borderStrong : Theme.separator,
                                          lineWidth: prefs.highContrast ? 2 : 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
                .animation(.easeOut(duration: Theme.Motion.quick), value: configuration.isPressed)
                .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, new in new && prefs.hapticsOnEveryTap }
        }

        private var foreground: Color {
            switch kind {
            case .primary: Theme.onAccent
            case .destructive: Theme.onDanger
            case .secondary, .quiet: Theme.accent
            }
        }

        private var background: Color {
            switch kind {
            case .primary: Theme.accentFill
            case .destructive: Theme.danger
            case .secondary: Theme.surface
            case .quiet: .clear
            }
        }
    }
}

/// One of the three big Home actions. The first is filled (primary); the others are surface rows
/// with an accent icon. In Accessibility Mode they grow and drop the subtitle.
public struct BigActionButton: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    let primary: Bool
    let action: () -> Void
    @Environment(\.displayPreferences) private var prefs
    @State private var taps = 0

    public init(_ title: String, systemImage: String, subtitle: String? = nil, primary: Bool = false,
                action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.subtitle = subtitle; self.primary = primary
        self.action = action
    }

    public var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(primary ? Theme.onAccent : Theme.accent)
                    .frame(width: Theme.Icon.l, height: Theme.Icon.l)
                    .background(primary ? Color.white.opacity(0.14) : Theme.accentSoft,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                        .foregroundStyle(primary ? Theme.onAccent : Theme.textPrimary)
                    if let subtitle, !prefs.homeShowsOnlyActions {
                        Text(subtitle).font(TypeScale.callout)
                            .foregroundStyle(primary ? Theme.onAccent.opacity(0.92) : Theme.textSecondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(primary ? Theme.onAccent : Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, prefs.accessibilityMode ? Theme.Space.l : Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: prefs.accessibilityMode ? 88 : 72)
            .background(primary ? Theme.accentFill : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(prefs.highContrast ? Theme.borderStrong : (primary ? .clear : Theme.separator),
                                  lineWidth: prefs.highContrast ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: taps) { _, _ in prefs.hapticsOnEveryTap }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
    }
}

/// Opacity-only pressed state for custom button labels.
public struct PressableStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: Theme.Motion.quick), value: configuration.isPressed)
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
                Label("Repeat", systemImage: "speaker.wave.2")
            }
            .buttonStyle(KavachButtonStyle(.secondary))
            .accessibilityHint("Reads it out loud again")
        }
    }
}

/// Initials in a circle: the avatar when there is no Contacts photo.
public struct MonogramAvatar: View {
    let name: String
    let size: CGFloat
    let imageData: Data?
    public init(name: String, size: CGFloat = Theme.Icon.l, imageData: Data? = nil) {
        self.name = name; self.size = size; self.imageData = imageData
    }

    public static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    public var body: some View {
        Group {
            if let imageData, let ui = UIImage(data: imageData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Text(Self.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accentSoft)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Wrapping row of chips (relationship quick picks). Wraps instead of shrinking labels.
public struct FlowLayout: Layout {
    public var spacing: CGFloat = Theme.Space.xs
    public init(spacing: CGFloat = Theme.Space.xs) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxWidth), height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

