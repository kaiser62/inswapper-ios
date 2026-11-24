import PhotosUI
import UniformTypeIdentifiers
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// App data locations and the observable face library used by the UI. Nothing here ever leaves the device.
enum AppData {
    static let support: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let patchCacheRoot = support.appendingPathComponent("patchcache").excludedFromBackup()
    static let facesDir = support.appendingPathComponent("faces").excludedFromBackup()
    static let videosDir = support.appendingPathComponent("videos").excludedFromBackup()
    /// File of the video currently open in the player (it cannot be deleted from the library meanwhile).
    nonisolated(unsafe) static var openVideoFile: String?
    static var cacheCapBytes: Int64 {
        let gb = UserDefaults.standard.object(forKey: "cacheCapGB") as? Double ?? 2
        return Int64(gb * 1_000_000_000)
    }
    static func jpeg(_ img: CGImage, quality: CGFloat = 0.8) -> Data? { UIImage(cgImage: img).jpegData(compressionQuality: quality) }
}

@MainActor
final class FaceStore: ObservableObject {
    static let shared = FaceStore()
    private let lib = FaceLibrary(directory: AppData.facesDir)
    @Published private(set) var entries: [FaceLibrary.Entry] = []
    init() { entries = lib.entries }
    private func refresh() { entries = lib.entries }

    func thumbnail(_ id: String) -> UIImage? { lib.thumbnail(id: id).flatMap { UIImage(data: $0) } }

    /// Averaged identity -> latent (needs the pipeline's emap).
    func latent(id: String, pipeline: FacePipeline) -> [Float]? {
        pipeline.latent(fromEmbeddings: lib.embeddings(id: id))
    }
    func add(name: String, embedding: [Float], thumb: Data?) -> FaceLibrary.Entry { let e = lib.add(name: name, embedding: embedding, thumbnailJPEG: thumb); refresh(); return e }
    func addPhoto(id: String, embedding: [Float]) { lib.addPhoto(id: id, embedding: embedding); refresh() }
    func rename(_ id: String, _ name: String) { lib.rename(id: id, to: name); refresh() }
    func delete(_ id: String) { lib.delete(id: id); refresh() }
    func exportData() -> Data? { lib.exportData() }
    func importData(_ d: Data) -> Int { let n = lib.importData(d); refresh(); return n }
}

/// Detects the largest face in a photo and returns its embedding + a small JPEG thumbnail.
enum FaceIngest {
    static func embed(photo data: Data, pipeline p: FacePipeline) throws -> (embedding: [Float], thumb: Data?) {
        let buf = try PixelBuf.load(data: data)
        guard let f = try p.detect(buf).max(by: { $0.area < $1.area }) else { throw PipelineError.noFace }
        let thumb = ImageFile.cgImage(data: data, maxSide: 200).flatMap { AppData.jpeg($0) }
        return (try p.embedding(forSource: buf, face: f), thumb)
    }
}

struct FacesView: View {
    @ObservedObject private var store = FaceStore.shared
    @State private var newItems: [PhotosPickerItem] = []
    @State private var addTarget: FaceLibrary.Entry?
    @State private var showAddPicker = false
    @State private var addItems: [PhotosPickerItem] = []
    @State private var renaming: FaceLibrary.Entry?
    @State private var newName = ""
    @State private var note = "Add 1-8 photos of one person. Photos are analysed on this device; only a 512-number identity and a small thumbnail are kept."
    @State private var busy = false
    @State private var importing = false
    @State private var shareURL: URL?

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PhotosPicker(selection: $newItems, maxSelectionCount: 8, matching: .images) { Label("New face from photos", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button { exportBackup() } label: { Label("Back up", systemImage: "square.and.arrow.up") }.buttonStyle(SoftButtonStyle()).disabled(store.entries.isEmpty)
                        Button { importing = true } label: { Label("Restore", systemImage: "square.and.arrow.down") }.buttonStyle(SoftButtonStyle())
                    }.font(.footnote)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 12) {
                        ForEach(store.entries, id: \.id) { e in
                            VStack(spacing: 4) {
                                Group {
                                    if let img = store.thumbnail(e.id) { Image(uiImage: img).resizable().scaledToFill() } else { Theme.surfaceRaised }
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: Theme.radiusSmall))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.line))
                                Text(e.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                Text("\(e.photoCount) photo\(e.photoCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(Theme.muted)
                            }
                            .accessibilityElement(children: .combine)
                            .contextMenu {
                                Button("Add photos") { addTarget = e; showAddPicker = true }
                                Button("Rename") { newName = e.name; renaming = e }
                                Button("Delete", role: .destructive) { store.delete(e.id) }
                            }
                        }
                    }
                    if !store.entries.isEmpty { Text("Touch and hold a face for options. Pick faces in the Photo and Player tabs.").font(.caption).foregroundStyle(.secondary) }
                }.padding()
            }
            .navigationTitle("Faces")
        .onChange(of: newItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items; newItems = []
            Task { await ingest(picked, into: nil) }
        }
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty, let t = addTarget else { return }
            let picked = items; addItems = []
            Task { await ingest(picked, into: t); addTarget = nil }
        }
        .photosPicker(isPresented: $showAddPicker, selection: $addItems, maxSelectionCount: 8, matching: .images)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            guard case let .success(u) = r else { return }
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u) { let n = store.importData(d); note = n > 0 ? "Restored \(n) face\(n == 1 ? "" : "s")." : "That file is not a face backup." }
            else { note = "Could not read that file." }
        }
        .sheet(item: $shareURL) { u in ShareSheet(url: u) }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { store.rename(r.id, newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func exportBackup() {
        guard let d = store.exportData() else { return }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("faces-backup.json")
        do { try d.write(to: u, options: .atomic); shareURL = u } catch { note = "Backup failed." }
    }

    private func ingest(_ items: [PhotosPickerItem], into target: FaceLibrary.Entry?) async {
        busy = true; defer { busy = false }
        note = "Analysing \(items.count) photo\(items.count == 1 ? "" : "s")…"
        do {
            let p = try await SharedPipeline.get()
            var ok = 0, skipped = 0
            var entry = target
            for it in items {
                guard let d = try? await it.loadTransferable(type: Data.self) else { skipped += 1; continue }
                do {
                    let r = try await Task.detached(priority: .userInitiated) { Box(v: try FaceIngest.embed(photo: d, pipeline: p)) }.value.v
                    if let e = entry { store.addPhoto(id: e.id, embedding: r.embedding) }
                    else { entry = store.add(name: "Face \(store.entries.count + 1)", embedding: r.embedding, thumb: r.thumb) }
                    ok += 1
                } catch { skipped += 1 }
            }
            note = "Added \(ok) photo\(ok == 1 ? "" : "s")" + (skipped > 0 ? ", \(skipped) had no usable face." : ".")
            AppLog.log(note, "faces")
        } catch { note = "Failed: \(error.localizedDescription)"; AppLog.log(note, "faces") }
    }
}

/// Sheet listing library faces; `onPick` receives the entry's averaged latent.
struct FacePickerSheet: View {
    @ObservedObject private var store = FaceStore.shared
    @Environment(\.dismiss) private var dismiss
    let onPick: (FaceLibrary.Entry) -> Void
    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty { Text("No saved faces yet. Add some in the Faces tab.").foregroundStyle(.secondary).padding() }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                            ForEach(store.entries, id: \.id) { e in
                                Button { onPick(e); dismiss() } label: {
                                    VStack {
                                        Group { if let img = store.thumbnail(e.id) { Image(uiImage: img).resizable().scaledToFill() } else { Color.gray.opacity(0.3) } }
                                            .frame(width: 90, height: 90).clipShape(Circle())
                                        Text(e.name).font(.footnote).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding()
                    }
                }
            }
            .navigationTitle("Saved faces")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - video library UI

@MainActor
final class VideoStore: ObservableObject {
    static let shared = VideoStore()
    let lib = VideoLibrary(directory: AppData.videosDir)
    private let downloader = VideoDownloader()
    @Published private(set) var entries: [VideoLibrary.Entry] = []
    @Published var message = ""
    @Published var progress: Double?      // 0...1 while downloading
    @Published var busy = false
    init() { entries = lib.entries }
    private func refresh() { entries = lib.entries }
    var totalMB: Double { Double(lib.totalBytes) / 1e6 }

    func url(_ e: VideoLibrary.Entry) -> URL { lib.url(of: e) }
    func thumbnail(_ e: VideoLibrary.Entry) -> UIImage? { UIImage(contentsOfFile: lib.thumbnailURL(of: e).path) }
    func delete(_ e: VideoLibrary.Entry) { lib.delete(id: e.id); refresh() }

    /// Moves a temp file (Photos / Files pick) into the library and returns its entry.
    func importFile(_ url: URL, title: String, source: String) async -> VideoLibrary.Entry? {
        do { let e = try await lib.add(moving: url, title: title, source: source); refresh(); return e }
        catch { message = error.localizedDescription; AppLog.log("import failed: \(error.localizedDescription)", "videos"); return nil }
    }

    /// Downloads a direct https link. Returns the new entry, or nil (message explains).
    func download(_ text: String) async -> VideoLibrary.Entry? {
        guard !busy else { return nil }
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { message = "That is not a valid link."; return nil }
        busy = true; progress = 0; message = "Downloading…"
        defer { busy = false; progress = nil }
        AppLog.log("download \(VideoDownloader.safeName(u))", "videos")
        do {
            let f = try await downloader.download(u) { [weak self] w, t in
                Task { @MainActor in if t > 0 { self?.progress = Double(w) / Double(t) } }
            }
            message = "Checking the video…"
            let e: VideoLibrary.Entry
            do { e = try await lib.add(moving: f, title: u.deletingPathExtension().lastPathComponent, source: u.host ?? "web") }
            catch { try? FileManager.default.removeItem(at: f); throw error }   // do not leave the rejected download behind
            refresh(); message = "Added."
            return e
        } catch {
            message = error.localizedDescription + (downloader.canResume ? " Tap Download again to resume." : "")
            AppLog.log("download failed: \(error.localizedDescription)", "videos")
            return nil
        }
    }
    func cancelDownload() { downloader.cancel() }
}

struct VideoLibrarySheet: View {
    @ObservedObject private var store = VideoStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    let onPick: (VideoLibrary.Entry) -> Void
    /// Inside the Library tab: no navigation stack or Close button of its own.
    var embedded = false

    var body: some View {
        if embedded { content } else {
            NavigationStack {
                content.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
    }

    private var content: some View {
            List {
                Section("Add from a link") {
                    TextField("https://…/video.mp4", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        Button("Paste") { if let t = UIPasteboard.general.string { link = t } }
                        Spacer()
                        Button("Try an example") { link = "https://assets.mixkit.co/videos/2960/2960-720.mp4" }
                    }.font(.footnote)
                    HStack {
                        Button("Download") { Task { if let e = await store.download(link) { link = ""; onPick(e); dismiss() } } }.disabled(store.busy || link.isEmpty)
                        if store.busy { Button("Cancel", role: .destructive) { store.cancelDownload() } }
                    }
                    if let p = store.progress { ProgressView(value: p) }
                    if !store.message.isEmpty { Text(store.message).font(.footnote).foregroundStyle(.secondary) }
                    Text("Direct links to .mp4 / .mov / .m4v files only (https). Use videos you have the right to use.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Saved videos (\(String(format: "%.0f", store.totalMB)) MB)") {
                    if store.entries.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    ForEach(store.entries) { e in
                        Button { onPick(e); dismiss() } label: {
                            HStack {
                                Group { if let t = store.thumbnail(e) { Image(uiImage: t).resizable().scaledToFill() } else { Color.gray.opacity(0.3) } }
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(e.title).lineLimit(1)
                                    Text("\(e.width)×\(e.height) · \(Int(e.duration)) s · \(String(format: "%.0f", Double(e.bytes) / 1e6)) MB · \(e.source)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }.onDelete { idx in
                        for e in idx.map({ store.entries[$0] }) {
                            if e.file == AppData.openVideoFile { store.message = "That video is open in the player. Open another one first."; continue }
                            store.delete(e)
                        }
                    }
                }
            }
            .navigationTitle("Videos")
    }
}
