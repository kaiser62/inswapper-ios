import SwiftUI

enum AppTab: String { case player, photo, library, settings }

/// Cross-tab navigation: the Library can ask the Player to open a saved video.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab
    @Published var pendingVideo: VideoLibrary.Entry?
    init(tab: AppTab = .player) { self.tab = tab }
}
