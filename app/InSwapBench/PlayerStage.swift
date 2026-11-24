import SwiftUI

/// The pinned video area: the picture, a status badge and the transport on a bottom scrim.
struct PlayerStage<Video: View>: View {
    let state: PlayerLayoutState
    let actions: PlayerLayoutActions
    @ViewBuilder let video: () -> Video

    @Binding var theater: Bool
    @State private var skips = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if state.hasVideo {
                    video().aspectRatio(state.aspect, contentMode: .fit)
                } else {
                    if state.videoPicked {
                        ContentUnavailableView {
                            Label("Video ready", systemImage: "checkmark.circle")
                        } actions: {
                            Button("Choose face", action: actions.chooseFace).buttonStyle(CompactPrimaryButtonStyle())
                        }
                    } else {
                        ContentUnavailableView {
                            Label("No video yet", systemImage: "film")
                        } actions: {
                            Button("Choose video", action: actions.chooseVideo).buttonStyle(CompactPrimaryButtonStyle())
                        }
                    }
                }
                if state.hasVideo {
                    VStack {
                        HStack {
                            if !state.badge.isEmpty && !theater {
                                Text(state.badge).font(.footnote.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                            Spacer()
                            Button(action: actions.toggleOverlay) {
                                Label(state.overlay ? "Swap on" : "Swap off", systemImage: state.overlay ? "face.smiling.inverse" : "face.dashed")
                                    .font(.footnote.bold()).padding(.horizontal, 10).frame(minHeight: Theme.hit)
                                    .foregroundStyle(state.overlay ? Theme.accent : Theme.muted)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                            .sensoryFeedback(.selection, trigger: state.overlay)
                            .accessibilityLabel("Face swap overlay")
                            .accessibilityInputLabels([state.overlay ? "Swap on" : "Swap off", "Face swap overlay"])   // Voice Control: the words on screen still work
                            .accessibilityValue(state.overlay ? "On" : "Off")
                            Button(theater ? "Exit theater" : "Theater", systemImage: theater ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                                withAnimation(Theme.spring) { theater.toggle() }
                            }
                            .labelStyle(.iconOnly).font(.footnote.bold())
                            .frame(minWidth: Theme.hit, minHeight: Theme.hit)
                            .background(.black.opacity(0.55), in: Circle())
                        }
                        Spacer()
                    }
                    .padding(Theme.gap)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .modifier(StageSizing(theater: theater, hasVideo: state.hasVideo, aspect: state.aspect))
            if state.hasVideo { transport }
        }
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: theater ? 0 : Theme.radius))
        .overlay { if !theater { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) } }
        .padding(.horizontal, theater ? 0 : Theme.pad)
    }

    private var transport: some View {
        VStack(spacing: 0) {
            PlayerScrubber(time: state.time, duration: state.duration, ranges: state.ranges,
                           onScrub: actions.scrub, onStart: actions.scrubStart, onEnd: actions.scrubEnd)
            HStack(spacing: Theme.gap) {
                Text(PlayerScrubber.clock(state.time)).font(.footnote.monospacedDigit())
                    .contentTransition(.numericText(value: state.time))
                    .animation(Theme.spring, value: Int(state.time))
                Spacer()
                skip("Back 5 seconds", "gobackward.5", -5)
                Button(state.playing ? "Pause" : "Play", systemImage: state.playing ? "pause.fill" : "play.fill", action: actions.togglePlay)
                    .labelStyle(.iconOnly).font(.title3)
                    .foregroundStyle(Theme.background)
                    .frame(width: Theme.hit, height: Theme.hit)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.25), radius: 6, y: 2)
                    .sensoryFeedback(.impact(weight: .medium), trigger: state.playing)
                skip("Forward 5 seconds", "goforward.5", 5)
                Spacer()
                Text(PlayerScrubber.clock(state.duration)).font(.footnote.monospacedDigit())
            }
        }
        .padding(.horizontal, Theme.gap)
        .padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.white)
    }

    private func skip(_ label: String, _ symbol: String, _ delta: Double) -> some View {
        Button(label, systemImage: symbol) {
            actions.scrubStart()
            actions.scrub(min(max(0, state.time + delta), state.duration))
            actions.scrubEnd()
            skips += 1
        }
        .labelStyle(.iconOnly).font(.title3)
        .frame(minWidth: Theme.hit, minHeight: Theme.hit)
        .sensoryFeedback(.impact(weight: .light), trigger: skips)
    }
}

/// Stage height: follows the video's aspect (no letterbox strip), capped so portrait clips leave room for the controls.
private struct StageSizing: ViewModifier {
    let theater: Bool, hasVideo: Bool, aspect: CGFloat
    func body(content: Content) -> some View {
        if theater { content.containerRelativeFrame(.vertical) { h, _ in h * 0.8 } }
        else if hasVideo { content.aspectRatio(aspect, contentMode: .fit).frame(maxHeight: 360) }
        else { content.frame(height: 260) }
    }
}
