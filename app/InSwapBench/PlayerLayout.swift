import SwiftUI

/// Plain values the Player layout draws (the live Player and the CI previews both fill this in).
struct PlayerLayoutState {
    var hasVideo = false
    var aspect: CGFloat = 16.0 / 9.0
    var time = 0.0
    var duration = 0.0
    var playing = false
    var ranges: [ClosedRange<Double>] = []
    var badge = ""
    var videoDetail: String?
    var face: CGImage?
    var status = ""
    var busy = false
}

struct PlayerLayoutActions {
    var chooseVideo: () -> Void = {}
    var chooseFace: () -> Void = {}
    var togglePlay: () -> Void = {}
    var export: () -> Void = {}
    var settings: () -> Void = {}
    var scrub: (Double) -> Void = { _ in }
    var scrubStart: () -> Void = {}
    var scrubEnd: () -> Void = {}
}

/// Player screen: video pinned at the top with the transport over a scrim, sources, mode and the Export button below.
struct PlayerLayout<Video: View>: View {
    let state: PlayerLayoutState
    @Binding var mode: PlayMode
    let actions: PlayerLayoutActions
    @ViewBuilder let video: () -> Video
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: Theme.gap) {
            PlayerStage(state: state, actions: actions, video: video)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Theme.gap)) : AnyLayout(HStackLayout(spacing: Theme.gap))
                    layout {
                        Button(action: actions.chooseVideo) {
                            SourceChip(title: "Video", detail: state.videoDetail ?? "Choose", systemImage: "film")
                        }
                        Button(action: actions.chooseFace) {
                            SourceChip(title: "Face", detail: state.face == nil ? "Choose" : "Selected", systemImage: "person.crop.square", thumbnail: state.face)
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                    PlayerModeCard(mode: $mode)
                    if !state.status.isEmpty {
                        Label(state.status, systemImage: state.busy ? "hourglass" : "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if typeSize.isAccessibilitySize { exportBar.padding(.horizontal, -Theme.pad) }
                }
                .padding(.horizontal, Theme.pad)
            }
            if !typeSize.isAccessibilitySize { exportBar }
        }
        .background(Theme.background)
    }

    private var exportBar: some View {
            HStack(spacing: Theme.gap) {
                Button("Export video", systemImage: "square.and.arrow.up", action: actions.export)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!state.hasVideo)
                    .opacity(state.hasVideo ? 1 : 0.4)
                Button("Settings", systemImage: "slider.horizontal.3", action: actions.settings)
                    .labelStyle(.iconOnly).font(.title3)
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.horizontal, Theme.pad)
    }
}
