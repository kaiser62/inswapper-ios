import PhotosUI
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
    static let patchCacheRoot = support.appendingPathComponent("patchcache")
    static let facesDir = support.appendingPathComponent("faces")
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
        FaceLibrary.averaged(lib.embeddings(id: id)).map { pipeline.latent(fromEmbedding: $0) }
    }
    func add(name: String, embedding: [Float], thumb: Data?) -> FaceLibrary.Entry { let e = lib.add(name: name, embedding: embedding, thumbnailJPEG: thumb); refresh(); return e }
    func addPhoto(id: String, embedding: [Float]) { lib.addPhoto(id: id, embedding: embedding); refresh() }
    func rename(_ id: String, _ name: String) { lib.rename(id: id, to: name); refresh() }
    func delete(_ id: String) { lib.delete(id: id); refresh() }
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
    @State private var addTo: FaceLibrary.Entry?
    @State private var addItems: [PhotosPickerItem] = []
    @State private var renaming: FaceLibrary.Entry?
    @State private var newName = ""
    @State private var note = "Add 1-8 photos of one person. Photos are analysed on this device; only a 512-number identity and a small thumbnail are kept."
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PhotosPicker(selection: $newItems, maxSelectionCount: 8, matching: .images) { Label("New face from photos", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(store.entries, id: \.id) { e in
                            VStack {
                                Group {
                                    if let img = store.thumbnail(e.id) { Image(uiImage: img).resizable().scaledToFill() } else { Color.gray.opacity(0.3) }
                                }.frame(width: 90, height: 90).clipShape(Circle())
                                Text(e.name).font(.footnote).lineLimit(1)
                                Text("\(e.photoCount) photo\(e.photoCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("Add photos") { addTo = e }
                                Button("Rename") { newName = e.name; renaming = e }
                                Button("Delete", role: .destructive) { store.delete(e.id) }
                            }
                        }
                    }
                    if !store.entries.isEmpty { Text("Touch and hold a face for options. Pick faces in the Photo and Player tabs.").font(.caption).foregroundStyle(.secondary) }
                }.padding()
            }
            .navigationTitle("Faces")
        }
        .onChange(of: newItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items; newItems = []
            Task { await ingest(picked, into: nil) }
        }
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty, let t = addTo else { return }
            let picked = items; addItems = []; addTo = nil
            Task { await ingest(picked, into: t) }
        }
        .photosPicker(isPresented: Binding(get: { addTo != nil }, set: { if !$0 { addTo = nil } }), selection: $addItems, maxSelectionCount: 8, matching: .images)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { store.rename(r.id, newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
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
