import SwiftUI

/// Confirmation sheet: what will be made, what it costs, one Start button.
struct ExportSheet: View {
    let plan: ExportEngine.Plan
    let duration: Double
    let swapsPerSecond: Double
    let strength: Int
    let swapperName: String
    let freeBytes: Int64
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var seconds: Double { plan.seconds(swapsPerSecond: swapsPerSecond) }
    private var enoughSpace: Bool { freeBytes >= plan.diskNeeded }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Output", "\(plan.width)×\(plan.height), HEVC with audio")
                    row("Length", Self.clock(duration))
                    row("Swapper", "\(swapperName), strength \(strength)")
                }
                .listRowBackground(Theme.surface)
                Section {
                    if plan.alreadyRendered > 0 {
                        row("Already rendered", "\(plan.alreadyRendered) of \(plan.frames) frames")
                    }
                    row("Estimated time", "about \(Self.minutes(seconds)) on a cool phone")
                    row("Free space", String(format: "%.1f GB (needs %.1f GB)", Double(freeBytes) / 1e9, Double(plan.diskNeeded) / 1e9))
                } footer: {
                    Text(enoughSpace ? "Keep the app open while it renders; it pauses by itself if the phone gets too hot or you leave the app, and resumes where it stopped." : "Not enough free space. Free some storage or clear the render cache in Settings, then try again.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Export video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button { dismiss(); onStart() } label: { Text("Start export").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!enoughSpace)
                    .padding()
                    .background(Theme.background)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).multilineTextAlignment(.trailing) }
    }
    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
    static func minutes(_ s: Double) -> String {
        let m = Int((s / 60).rounded(.up))
        return m < 1 ? "under a minute" : m == 1 ? "1 minute" : "\(m) minutes"
    }
}
