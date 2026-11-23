import SwiftUI

/// The app's visual constants: one place for colors, spacing and radii so every screen stays uniform.
enum Theme {
    // Palette ported from the VisoSwap /mobile web UI (frontend/src/index.css): teal on near-black.
    static let accent = Color(red: 0x32 / 255, green: 0xBB / 255, blue: 0xD0 / 255)
    static let background = Color(red: 0x09 / 255, green: 0x0C / 255, blue: 0x0F / 255)
    static let surface = Color(red: 0x11 / 255, green: 0x17 / 255, blue: 0x1C / 255)
    static let surfaceRaised = Color(red: 0x18 / 255, green: 0x21 / 255, blue: 0x29 / 255)
    static let line = Color(red: 0x29 / 255, green: 0x36 / 255, blue: 0x40 / 255)
    static let muted = Color(red: 0x8D / 255, green: 0xA1 / 255, blue: 0xAD / 255)
    static let active = Color(red: 0x15 / 255, green: 0x3B / 255, blue: 0x43 / 255)
    static let good = Color(red: 0x5D / 255, green: 0xCC / 255, blue: 0x8B / 255)
    static let bad = Color(red: 0xEF / 255, green: 0x72 / 255, blue: 0x65 / 255)
    static let warn = Color(red: 1.0, green: 0.70, blue: 0.30)

    static let pad: CGFloat = 16
    static let gap: CGFloat = 12
    static let radius: CGFloat = 16
    static let radiusSmall: CGFloat = 12
    static let radiusChip: CGFloat = 8
    static let hit: CGFloat = 44

    static let spring = Animation.snappy(duration: 0.28)
}

extension View {
    /// Bordered card surface (VisoSwap: rounded-2xl border-line bg-card).
    func card() -> some View {
        background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line))
    }

    /// Dark scheme and the accent tint: sheets and covers do not always inherit them from the root.
    func themed() -> some View { tint(Theme.accent).preferredColorScheme(.dark) }
}
