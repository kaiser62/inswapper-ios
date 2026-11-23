import SwiftUI

/// The one prominent action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: Theme.hit)
            .padding(.vertical, 4)
            .background(Theme.accent, in: .rect(cornerRadius: Theme.radius))
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
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}
