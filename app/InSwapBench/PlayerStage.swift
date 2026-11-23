import SwiftUI

/// The pinned video area: the picture, a status badge and the transport on a bottom scrim.
struct PlayerStage<Video: View>: View {
    let state: PlayerLayoutState
    let actions: PlayerLayoutActions
    @ViewBuilder let video: () -> Video

    var body: some View {
        ZStack {
            Color.black
            if state.hasVideo {
                video().aspectRatio(state.aspect, contentMode: .fit)
            } else {
                ContentUnavailableView {
                    Label("No video yet", systemImage: "film")
                } description: {
                    Text("Choose a video and a face to start.")
                } actions: {
                    Button("Choose video", action: actions.chooseVideo).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
            if state.hasVideo {
                VStack {
                    HStack {
                        if !state.badge.isEmpty {
                            Text(state.badge).font(.footnote.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        Spacer()
                    }
                    Spacer()
                    transport
                }
                .padding(Theme.gap)
            }
        }
        .containerRelativeFrame(.vertical) { h, _ in h * 0.44 }
        .clipShape(.rect(cornerRadius: Theme.radius))
        .padding(.horizontal, Theme.pad)
    }

    private var transport: some View {
        VStack(spacing: 0) {
            PlayerScrubber(time: state.time, duration: state.duration, ranges: state.ranges,
                           onScrub: actions.scrub, onStart: actions.scrubStart, onEnd: actions.scrubEnd)
            HStack {
                Button(state.playing ? "Pause" : "Play", systemImage: state.playing ? "pause.fill" : "play.fill", action: actions.togglePlay)
                    .labelStyle(.iconOnly).font(.title2).frame(minWidth: Theme.hit, minHeight: Theme.hit)
                Text("\(PlayerScrubber.clock(state.time)) / \(PlayerScrubber.clock(state.duration))")
                    .font(.footnote.monospacedDigit())
                Spacer()
            }
        }
        .padding(.horizontal, Theme.gap)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).padding(.top, -Theme.pad * 2))
        .foregroundStyle(.white)
    }
}
