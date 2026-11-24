import AVKit
import SwiftUI

/// Finished exports (Documents/Exports): play, share, delete. The VisoSwap "Saved Takes" list, on device.
struct TakesView: View {
    struct Take: Identifiable { let url: URL; let date: Date; let bytes: Int64; var id: URL { url } }
    @State private var takes: [Take] = []
    @State private var playing: Take?
    @State private var sharing: URL?
    @State private var deleting: Take?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.gap) {
                if takes.isEmpty {
                    ContentUnavailableView("No exports yet", systemImage: "film.stack",
                                           description: Text("Finished videos from the Player's Export button appear here."))
                        .padding(.top, 40)
                }
                ForEach(takes) { t in row(t) }
            }
            .padding(Theme.pad)
        }
        .onAppear(perform: reload)
        .sheet(item: $playing) { t in
            TakePlayer(url: t.url).themed()
        }
        .sheet(item: $sharing) { ShareSheet(url: $0) }
        .confirmationDialog("Delete this video?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let t = deleting { try? FileManager.default.removeItem(at: t.url); reload() }; deleting = nil }
        } message: { Text("This cannot be undone.") }
    }

    private func row(_ t: Take) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                Text("\(t.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: t.bytes, countStyle: .file))")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            HStack(spacing: Theme.gap) {
                Button("Play", systemImage: "play.fill") { playing = t }.buttonStyle(PrimaryButtonStyle())
                Button("Share", systemImage: "square.and.arrow.up") { sharing = t.url }.labelStyle(.iconOnly).buttonStyle(SoftButtonStyle())
                Button("Delete", systemImage: "trash") { deleting = t }.labelStyle(.iconOnly).foregroundStyle(Theme.bad).buttonStyle(SoftButtonStyle())
            }
        }
        .padding(Theme.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func reload() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: ExportSession.exportsDirectory, includingPropertiesForKeys: keys)) ?? []
        takes = urls.filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Take(url: u, date: v?.contentModificationDate ?? .distantPast, bytes: Int64(v?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }
}

/// Holds its AVPlayer in state so it is not recreated on every redraw; plays on appear, stops on disappear.
private struct TakePlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear { let p = AVPlayer(url: url); player = p; p.play() }
            .onDisappear { player?.pause(); player = nil }
    }
}
