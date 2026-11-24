import SwiftUI

/// The one prominent action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(enabled ? Theme.background : Theme.muted)
            .frame(maxWidth: .infinity, minHeight: Theme.hit)
            .padding(.vertical, 4)
            .background(enabled ? Theme.accent : Theme.surfaceRaised, in: .rect(cornerRadius: Theme.radiusSmall))
            .shadow(color: Theme.accent.opacity(enabled ? 0.25 : 0), radius: 8, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Quiet buttons and chips: raised surface, no outline.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(minHeight: Theme.hit)
            .padding(.horizontal, Theme.gap)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Compact prominent button for toolbars and button rows (dark text on the teal fill).
struct CompactPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(enabled ? Theme.background : Theme.muted)
            .padding(.horizontal, Theme.gap).frame(minHeight: Theme.hit)
            .background(enabled ? Theme.accent : Theme.surfaceRaised, in: .rect(cornerRadius: Theme.radiusSmall))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Compact quiet button: raised surface with a hairline border.
struct CompactSoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.gap).frame(minHeight: Theme.hit)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.line))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}
