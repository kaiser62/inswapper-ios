import SwiftUI

/// Full-screen cover shown for the whole export: progress, then the result (save / share).
struct ExportProgressView: View {
    @ObservedObject var session: ExportSession
    let onClose: () -> Void
    @State private var confirmCancel = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            switch session.state {
            case .idle, .running: running
            case .done(let url): finished(url)
            case .failed(let m): message("Export failed", m, symbol: "exclamationmark.triangle")
            case .cancelled: message("Export cancelled", "Frames already rendered are kept, so exporting again resumes where this stopped.", symbol: "xmark.circle")
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .interactiveDismissDisabled()
        .confirmationDialog("Cancel export?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel export", role: .destructive) { session.cancel() }
            Button("Keep exporting", role: .cancel) {}
        } message: { Text("Rendered frames are kept, so you can resume later.") }
    }

    private var running: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(session.phase == .rendering ? "Step 1 of 2: swapping faces" : "Step 2 of 2: encoding video").font(.headline)
                Text(session.paused ? "Paused" : session.phase == .rendering ? "The slow part; the Neural Engine is swapping every frame." : "Almost there; this part is quick.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            ProgressView(value: session.fraction).progressViewStyle(.linear)
                .accessibilityLabel(session.phase == .rendering ? "Swapping faces" : "Encoding")
                .accessibilityValue("\(Int(session.fraction * 100)) percent")
            VStack(spacing: 4) {
                Text("\(session.done) of \(session.total) frames").monospacedDigit()
                Text(session.secondsLeft.map { "About \(ExportSheet.minutes($0)) left" } ?? "Estimating time…").foregroundStyle(.secondary)
                if session.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    Label(PlayerVM.thermalName(session.thermal) == "CRITICAL" ? "Phone is very hot: paused until it cools" : "Phone is hot; it may run slower", systemImage: "thermometer.high")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 12) {
                Button(session.paused ? "Resume" : "Pause", systemImage: session.paused ? "play.fill" : "pause.fill") { session.setPaused(!session.paused) }
                    .buttonStyle(CompactSoftButtonStyle())
                Button("Cancel", role: .destructive) { confirmCancel = true }.buttonStyle(CompactSoftButtonStyle(tint: Theme.bad))
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.good).accessibilityHidden(true)
            Text("Export finished").font(.title2.bold())
            Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
            Button { session.saveToPhotos(url) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                .buttonStyle(SoftButtonStyle())
            if let m = session.saveMessage { Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Button("Done", action: onClose).padding(.top, 8)
        }
    }

    private func message(_ title: String, _ body: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(body).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close", action: onClose).buttonStyle(PrimaryButtonStyle())
        }
    }
}
