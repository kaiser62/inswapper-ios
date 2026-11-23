import SwiftUI

/// The app's visual constants: one place for colors, spacing and radii so every screen stays uniform.
enum Theme {
    static let accent = Color(red: 0.55, green: 0.49, blue: 1.0)
    static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let surface = Color(red: 0.09, green: 0.09, blue: 0.125)
    static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.22)
    static let good = Color(red: 0.35, green: 0.80, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.70, blue: 0.30)

    static let pad: CGFloat = 16
    static let gap: CGFloat = 12
    static let radius: CGFloat = 18
    static let radiusSmall: CGFloat = 12
    static let hit: CGFloat = 44

    static let spring = Animation.snappy(duration: 0.28)
}

extension View {
    /// Dark scheme and the accent tint: sheets and covers do not always inherit them from the root.
    func themed() -> some View { tint(Theme.accent).preferredColorScheme(.dark) }
}
