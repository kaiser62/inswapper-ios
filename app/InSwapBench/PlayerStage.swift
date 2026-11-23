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
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .containerRelativeFrame(.vertical) { h, _ in h * 0.44 }
        .clipShape(.rect(cornerRadius: Theme.radius))
        .padding(.horizontal, Theme.pad)
    }

    private var transport: some View {
        VStack(spacing: 0) {
            PlayerScrubber(time: state.time, duration: state.duration, ranges: state.ranges,
                           onScrub: actions.scrub, onStart: actions.scrubStart, onEnd: actions.scrubEnd)
            HStack(spacing: Theme.gap) {
                Text(PlayerScrubber.clock(state.time)).font(.footnote.monospacedDigit())
                Spacer()
                skip("Back 5 seconds", "gobackward.5", -5)
                Button(state.playing ? "Pause" : "Play", systemImage: state.playing ? "pause.fill" : "play.fill", action: actions.togglePlay)
                    .labelStyle(.iconOnly).font(.title3)
                    .foregroundStyle(Theme.background)
                    .frame(width: Theme.hit, height: Theme.hit)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.25), radius: 6, y: 2)
                skip("Forward 5 seconds", "goforward.5", 5)
                Spacer()
                Text(PlayerScrubber.clock(state.duration)).font(.footnote.monospacedDigit())
            }
        }
        .padding(.horizontal, Theme.gap)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).padding(.top, -Theme.pad * 2))
        .foregroundStyle(.white)
    }

    private func skip(_ label: String, _ symbol: String, _ delta: Double) -> some View {
        Button(label, systemImage: symbol) {
            actions.scrubStart()
            actions.scrub(min(max(0, state.time + delta), state.duration))
            actions.scrubEnd()
        }
        .labelStyle(.iconOnly).font(.title3)
        .frame(minWidth: Theme.hit, minHeight: Theme.hit)
    }
}
