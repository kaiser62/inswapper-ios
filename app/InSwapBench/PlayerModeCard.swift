import SwiftUI

/// Live preview versus render ahead, with a one-line explanation of the chosen mode.
struct PlayerModeCard: View {
    @Binding var mode: PlayMode

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Picker("Mode", selection: $mode) {
                Text("Live").tag(PlayMode.livePreview)
                Text("Render ahead").tag(PlayMode.renderAhead)
            }
            .pickerStyle(.segmented)
            Text(mode == .livePreview
                 ? "Swaps while you watch. Instant after a seek; the face lags a little on fast motion."
                 : "Swaps every frame in the background. Green parts of the timeline are ready to play perfectly.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(Theme.gap)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
    }
}
