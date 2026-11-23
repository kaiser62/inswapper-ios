import PhotosUI
import SwiftUI

/// CI screenshot stand-ins for the Player (`-uiPreview player-loaded|player-empty|player-settings|player-video|player-face`). Placeholder content only.
struct PlayerPreview: View {
    let kind: String
    @State private var mode = PlayMode.renderAhead

    var body: some View {
        switch kind {
        case "player-settings":
            PlayerSettingsSheet(fastSwapper: .constant(true), strength: .constant(100), combo: .constant(false), hasFast: true,
                                costText: "About 4 min of rendering per minute of video on a cool phone.", cacheText: "840 MB of 2.0 GB",
                                diagnostics: "build 46 · mode A · video 1280x720\n15.2 swaps/s · thermal nominal", onClearCache: {}, onCopyDiagnostics: {})
        case "player-video":
            VideoSourceSheet(photosItem: .constant(nil), onFiles: {}, onSaved: {})
        case "player-face":
            FaceSourceSheet(photoItem: .constant(nil), canSave: true, onLibrary: {}, onSave: {})
        default:
            let loaded = kind == "player-loaded"
            PlayerLayout(state: state(loaded), mode: $mode, actions: PlayerLayoutActions()) {
                LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.5), Color(red: 0.55, green: 0.3, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "person.crop.rectangle").font(.system(size: 64)).foregroundStyle(.white.opacity(0.35)) }
            }
        }
    }

    private func state(_ loaded: Bool) -> PlayerLayoutState {
        var s = PlayerLayoutState()
        guard loaded else { s.status = "Pick a video and a source face."; return s }
        s.hasVideo = true; s.time = 21; s.duration = 60; s.playing = false
        s.ranges = [0...34, 41...48]
        s.badge = "8-bit · Render ahead"; s.videoDetail = "1:00 · 1280×720"; s.status = "Ready."
        return s
    }
}
