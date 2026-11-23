import SwiftUI

/// Live preview versus render ahead, with a one-line explanation of the chosen mode.
struct PlayerModeCard: View {
    @Binding var mode: PlayMode

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Segmented(options: [("Live", PlayMode.livePreview), ("Render ahead", PlayMode.renderAhead)], selection: $mode)
            Text(mode == .livePreview
                 ? "Swaps while you watch. Instant after a seek; the face lags a little on fast motion."
                 : "Swaps every frame in the background. Green parts of the timeline are ready to play perfectly.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(Theme.gap)
        .card()
    }
}
