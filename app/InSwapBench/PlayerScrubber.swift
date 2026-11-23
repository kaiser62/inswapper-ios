import SwiftUI

/// Timeline: rendered ranges are drawn inside the track; drag anywhere to scrub. VoiceOver gets an adjustable value.
struct PlayerScrubber: View {
    let time: Double
    let duration: Double
    let ranges: [ClosedRange<Double>]
    let onScrub: (Double) -> Void
    let onStart: () -> Void
    let onEnd: () -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width), d = max(duration, 0.001)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, r in
                    Capsule().fill(Theme.good)
                        .frame(width: max(3, w * (r.upperBound - r.lowerBound) / d), height: 4)
                        .offset(x: w * r.lowerBound / d)
                }
                Circle().fill(.white).frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: min(w, max(0, w * time / d)) - (dragging ? 9 : 6))
                    .animation(Theme.spring, value: dragging)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging { dragging = true; onStart() }
                    onScrub(min(d, max(0, d * v.location.x / w)))
                }
                .onEnded { _ in dragging = false; onEnd() })
        }
        .frame(height: Theme.hit)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.clock(time)) of \(Self.clock(duration))\(renderedSummary)")
        .accessibilityAdjustableAction { dir in
            let step = 5.0
            onStart(); onScrub(min(duration, max(0, time + (dir == .increment ? step : -step)))); onEnd()
        }
    }

    /// The green ranges, in words (colour alone must not carry this).
    private var renderedSummary: String {
        guard !ranges.isEmpty, duration > 0 else { return "" }
        let done = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        return ", \(min(100, Int(done / duration * 100))) percent rendered"
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
