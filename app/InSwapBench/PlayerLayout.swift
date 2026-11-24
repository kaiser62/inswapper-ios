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
    var overlay = true
    var speed = 1.0
}

struct PlayerLayoutActions {
    var chooseVideo: () -> Void = {}
    var chooseFace: () -> Void = {}
    var togglePlay: () -> Void = {}
    var export: () -> Void = {}
    var settings: () -> Void = {}
    var toggleOverlay: () -> Void = {}
    var setSpeed: (Double) -> Void = { _ in }
    var scrub: (Double) -> Void = { _ in }
    var scrubStart: () -> Void = {}
    var scrubEnd: () -> Void = {}
}

/// Player screen: video pinned at the top with the transport over a scrim, sources, mode and the Export button below.
struct PlayerLayout<Video: View>: View {
    let state: PlayerLayoutState
    @Binding var mode: PlayMode
    let actions: PlayerLayoutActions
    var startInTheater = false
    @ViewBuilder let video: () -> Video
    @State private var theater = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: Theme.gap) {
            PlayerStage(state: state, actions: actions, video: video, theater: $theater)
            if !theater { ScrollView {
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
                    if state.hasVideo { speedCard }
                    if !state.status.isEmpty {
                        Label(state.status, systemImage: state.busy ? "hourglass" : "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if typeSize.isAccessibilitySize { exportBar.padding(.horizontal, -Theme.pad) }
                }
                .padding(.horizontal, Theme.pad)
            } }
            if !theater && !typeSize.isAccessibilitySize { exportBar }
        }
        .background(Theme.background)
        .toolbar(theater ? .hidden : .automatic, for: .tabBar)
        .statusBarHidden(theater)
        .onAppear { if startInTheater { theater = true } }
        .onChange(of: state.status) { _, new in
            if !new.isEmpty { AccessibilityNotification.Announcement(new).post() }   // loading steps and errors are otherwise silent
        }
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Playback speed").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f×", state.speed)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.accent)
                if state.speed < 1 { Button("1×") { actions.setSpeed(1) }.buttonStyle(CompactSoftButtonStyle()) }
            }
            Slider(value: Binding(get: { state.speed }, set: { actions.setSpeed(($0 * 20).rounded() / 20) }), in: 0...1)
                .accessibilityLabel("Playback speed").accessibilityValue(String(format: "%.2f times", state.speed))
        }
        .padding(Theme.gap)
        .card()
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
