import SwiftUI
import PhotosUI
import Photos
import ImageIO

struct Box<T>: @unchecked Sendable { let v: T }

/// One target photo in the batch: its detected faces (largest first), which are selected, and the swapped result.
struct PhotoJob: Identifiable {
    let id = UUID()
    var data: Data                      // encoded original; decoded at swap time (keeps memory flat)
    var width: Int, height: Int
    var preview: CGImage               // downscaled target for the UI / face boxes
    var faces: [DetectedFace]          // sorted largest first
    var selected: Set<Int>             // default: the largest face only
    var resultURL: URL?
    var thumb: CGImage?
    var note = ""
}

enum ImageFile {
    /// Downscaled decode with EXIF orientation, for display.
    static func cgImage(url: URL, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }
    static func cgImage(data: Data, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }
}

@MainActor
final class PhotoVM: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var sourceImage: CGImage?
    @Published var jobs: [PhotoJob] = []
    @Published var timings = "build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")\n"

    private var pipe: FacePipeline?
    private var latent: [Float]?

    private func pipeline() async throws -> FacePipeline {
        if let p = pipe { return p }
        status = "Loading models (the first load compiles for the Neural Engine and can take a while)…"
        let t0 = Date()
        let p = try await SharedPipeline.get()
        pipe = p
        timings += String(format: "model load: %.0f ms\n", Date().timeIntervalSince(t0) * 1000)
        return p
    }

    private func stage(_ p: FacePipeline, _ prefix: String) -> String {
        "\(prefix): " + p.timings.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f", $0.key, $0.value) }.joined(separator: ", ") + " (ms)\n"
    }

    // MARK: source
    func setSource(_ data: Data) {
        guard !busy else { return }
        busy = true; latent = nil
        Task {
            defer { busy = false }
            do {
                let p = try await pipeline()
                status = "Analysing source face…"
                let box = try await Task.detached(priority: .userInitiated) { () -> Box<([Float], CGImage?)> in
                    let tl = Date()
                    let buf = try PixelBuf.load(data: data)
                    let loadMs = Date().timeIntervalSince(tl) * 1000
                    p.resetTimings(); p.addTiming("decode-image", loadMs)
                    guard let face = try p.detect(buf).max(by: { $0.area < $1.area }) else { throw PipelineError.noFace }
                    return Box(v: (try p.latent(forSource: buf, face: face), ImageFile.cgImage(data: data, maxSide: 400)))
                }.value
                latent = box.v.0; sourceImage = box.v.1
                timings += stage(p, "source")
                status = "Source face ready."
            } catch PipelineError.noFace {
                sourceImage = nil; status = "No face found in the source photo."
            } catch {
                status = "Source failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: targets (batch)
    func setTargets(_ datas: [Data], unreadable: Int = 0) {
        guard !datas.isEmpty else { status = "None of the selected photos could be read."; return }
        guard !busy else { status = "Busy: try the selection again in a moment."; return }
        busy = true
        for j in jobs { if let u = j.resultURL { try? FileManager.default.removeItem(at: u) } }
        jobs = []
        Task {
            defer { busy = false }
            do {
                let p = try await pipeline()
                var out: [PhotoJob] = []
                var failed = unreadable
                for (n, data) in datas.enumerated() {
                    status = "Detecting faces \(n + 1)/\(datas.count)…"
                    do {
                        let box = try await Task.detached(priority: .userInitiated) { () -> Box<PhotoJob> in
                            let tl = Date()
                            let buf = try PixelBuf.load(data: data)
                            let loadMs = Date().timeIntervalSince(tl) * 1000
                            p.resetTimings(); p.addTiming("decode-image", loadMs)
                            let faces = try p.detect(buf).sorted { $0.area > $1.area }
                            let (w, h) = PixelBuf.size(buf)
                            let prev = ImageFile.cgImage(data: data, maxSide: 1600) ?? PixelBuf.cgImage(from: buf)!
                            return Box(v: PhotoJob(data: data, width: w, height: h, preview: prev, faces: faces,
                                                   selected: faces.isEmpty ? [] : [0], note: faces.isEmpty ? "no face" : ""))
                        }.value
                        out.append(box.v)
                        timings += stage(p, "photo \(n + 1) \(box.v.width)x\(box.v.height) faces \(box.v.faces.count)")
                        jobs = out
                    } catch {
                        failed += 1
                        timings += "photo \(n + 1): failed (\(error.localizedDescription))\n"
                    }
                }
                status = "\(out.count) photo(s) ready" + (failed > 0 ? ", \(failed) could not be read" : "") + ". Largest face selected in each; tap Swap all, then edit faces from the full-screen view."
            } catch {
                status = "Target failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: swap
    func swapAll() {
        guard !busy, latent != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            let t0 = Date()
            for i in jobs.indices where !jobs[i].selected.isEmpty {
                status = "Swapping \(i + 1)/\(jobs.count)…"
                await render(i)
            }
            status = String(format: "Done (%.1f s).", Date().timeIntervalSince(t0))
        }
    }

    func reswap(_ id: UUID) {
        guard !busy, let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].selected.isEmpty else { return }
        busy = true
        Task { defer { busy = false }; status = "Swapping…"; await render(i); status = "Done." }
    }

    private func render(_ i: Int) async {
        guard let p = pipe, let lat = latent else { return }
        let job = jobs[i]
        let faces = job.selected.sorted().map { job.faces[$0] }
        let fb = Box(v: faces), data = job.data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swapped-\(job.id.uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        let t0 = Date()
        do {
            let thumb = try await Task.detached(priority: .userInitiated) { () -> Box<CGImage?> in
                let td = Date()
                let frame = try PixelBuf.load(data: data)
                p.resetTimings(); p.addTiming("decode-image", Date().timeIntervalSince(td) * 1000)
                let patches = try fb.v.map { try p.swap(frame: frame, face: $0, latent: lat) }
                let tc = Date()
                let out = try Compositor.composite(frame, patches: patches)
                p.addTiming("composite", Date().timeIntervalSince(tc) * 1000)
                let te = Date()
                try PixelBuf.writeJPEG(out, to: url, quality: 0.95)
                p.addTiming("encode", Date().timeIntervalSince(te) * 1000)
                let tt = Date()
                let th = ImageFile.cgImage(url: url, maxSide: 400)
                p.addTiming("thumb", Date().timeIntervalSince(tt) * 1000)
                return Box(v: th)
            }.value
            if let old = jobs[i].resultURL { try? FileManager.default.removeItem(at: old) }
            jobs[i].resultURL = url; jobs[i].thumb = thumb.v; jobs[i].note = ""
            timings += stage(p, "swap \(job.width)x\(job.height), \(faces.count) face(s)") + String(format: "swap total: %.0f ms\n", Date().timeIntervalSince(t0) * 1000)
        } catch {
            jobs[i].note = "failed: \(error.localizedDescription)"
        }
    }

    func toggle(_ id: UUID, face: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].selected.contains(face) { jobs[i].selected.remove(face) } else { jobs[i].selected.insert(face) }
    }

    func saveAllToPhotos() {
        let urls = jobs.compactMap { $0.resultURL }
        guard !urls.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in self.status = "Photos access denied (use Share in the full-screen view instead)." }; return
            }
            PHPhotoLibrary.shared().performChanges({
                for u in urls { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u) }
            }) { ok, err in
                Task { @MainActor in self.status = ok ? "Saved \(urls.count) to Photos." : "Save failed: \(err?.localizedDescription ?? "unknown") (use Share instead)." }
            }
        }
    }
}

// MARK: - views

struct PhotoView: View {
    @StateObject private var vm = PhotoVM()
    @State private var srcItem: PhotosPickerItem?
    @State private var tgtItems: [PhotosPickerItem] = []
    @State private var installed = ModelStore.isInstalled
    @State private var viewer: ViewerStart?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !installed {
                        Text("Models are not installed. Import models.zip in the Models & Bench tab first.").foregroundStyle(.red)
                    }
                    HStack {
                        PhotosPicker(selection: $srcItem, matching: .images) { Label("Source face", systemImage: "person.crop.square") }
                            .buttonStyle(.bordered)
                        PhotosPicker(selection: $tgtItems, maxSelectionCount: 12, matching: .images) { Label("Target photos", systemImage: "photo.stack") }
                            .buttonStyle(.bordered)
                    }
                    .disabled(vm.busy || !installed)
                    if let s = vm.sourceImage {
                        Image(decorative: s, scale: 1).resizable().scaledToFit().frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button("Swap all (\(vm.jobs.filter { !$0.selected.isEmpty }.count))") { vm.swapAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.busy || vm.sourceImage == nil || vm.jobs.allSatisfy { $0.selected.isEmpty })
                    if !vm.jobs.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                            ForEach(Array(vm.jobs.enumerated()), id: \.element.id) { i, job in
                                Button { viewer = ViewerStart(index: i) } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        Image(decorative: job.thumb ?? job.preview, scale: 1).resizable().scaledToFill()
                                            .frame(minWidth: 0, maxWidth: .infinity).frame(height: 140).clipped()
                                        Text(job.resultURL != nil ? "swapped" : (job.note.isEmpty ? "\(job.faces.count) face(s)" : job.note))
                                            .font(.caption2.bold()).padding(3).background(.black.opacity(0.6)).foregroundStyle(.white)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        if vm.jobs.contains(where: { $0.resultURL != nil }) {
                            Button("Save all to Photos") { vm.saveAllToPhotos() }.buttonStyle(.bordered)
                        }
                    }
                    if vm.busy { ProgressView() }
                    Text(vm.status).font(.footnote)
                    Text(vm.timings).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("InSwap")
        }
        .fullScreenCover(item: $viewer) { start in ResultViewer(vm: vm, index: start.index) }
        .onAppear { installed = ModelStore.isInstalled }
        .onChange(of: srcItem) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { vm.setSource(d) } }
        }
        .onChange(of: tgtItems) { _, items in
            guard !items.isEmpty else { return }
            vm.status = "Loading \(items.count) photo(s)…"
            Task {
                var datas: [Data] = []
                for it in items { if let d = try? await it.loadTransferable(type: Data.self) { datas.append(d) } }
                tgtItems = []   // so picking the same photos again fires onChange
                vm.setTargets(datas, unreadable: items.count - datas.count)
            }
        }
    }
}

struct ViewerStart: Identifiable { let id = UUID(); let index: Int }

/// Loads a downscaled image from a file off the main thread.
struct FileImage: View {
    let url: URL
    @State private var cg: CGImage?
    var body: some View {
        Group {
            if let cg { Image(decorative: cg, scale: 1).resizable().scaledToFit() } else { ProgressView() }
        }
        .task(id: url) {
            cg = nil
            let u = url
            cg = await Task.detached { ImageFile.cgImage(url: u, maxSide: 2400) }.value
        }
    }
}

struct ResultViewer: View {
    @ObservedObject var vm: PhotoVM
    @State var index: Int
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(vm.jobs.enumerated()), id: \.element.id) { i, job in
                    VStack {
                        if let url = job.resultURL {
                            FileImage(url: url).id(url)
                        } else {
                            Image(decorative: job.preview, scale: 1).resizable().scaledToFit()
                            Text(job.note.isEmpty ? "Not swapped yet" : job.note).font(.footnote).foregroundStyle(.white)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                    Spacer()
                    Text("\(index + 1) / \(vm.jobs.count)").font(.subheadline.bold())
                    Spacer()
                    if index < vm.jobs.count, let url = vm.jobs[index].resultURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.title2) }
                    }
                }
                .padding().foregroundStyle(.white)
                Spacer()
                if index < vm.jobs.count {
                    Button { editing = true } label: {
                        Label(vm.jobs[index].faces.count > 1 ? "Edit faces (\(vm.jobs[index].faces.count) found)" : "Edit", systemImage: "face.dashed")
                    }
                    .buttonStyle(.borderedProminent).padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $editing) {
            if index < vm.jobs.count { FaceEditSheet(vm: vm, jobID: vm.jobs[index].id) }
        }
    }
}

struct FaceEditSheet: View {
    @ObservedObject var vm: PhotoVM
    let jobID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let job = vm.jobs.first(where: { $0.id == jobID }) {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(decorative: job.preview, scale: 1).resizable().scaledToFit()
                            .overlay(GeometryReader { geo in
                                let k = geo.size.width / CGFloat(job.preview.width)
                                let kx = CGFloat(job.preview.width) / CGFloat(job.width)
                                ForEach(job.faces.indices, id: \.self) { i in
                                    let f = job.faces[i]
                                    Rectangle().stroke(job.selected.contains(i) ? Color.green : Color.white.opacity(0.8), lineWidth: 3)
                                        .contentShape(Rectangle())
                                        .onTapGesture { vm.toggle(jobID, face: i) }
                                        .frame(width: (f.x2 - f.x1) * kx * k, height: (f.y2 - f.y1) * kx * k)
                                        .position(x: (f.x1 + f.x2) / 2 * kx * k, y: (f.y1 + f.y2) / 2 * kx * k)
                                        .overlay(Text("\(i + 1)").font(.caption.bold()).padding(3).background(.black.opacity(0.6)).foregroundStyle(.white)
                                            .position(x: f.x1 * kx * k + 10, y: f.y1 * kx * k + 10))
                                }
                            })
                        if job.faces.isEmpty {
                            Text("No face detected in this photo.")
                        } else {
                            Text("Tap boxes or buttons to choose which faces are swapped. Face 1 is the largest.").font(.footnote)
                            HStack {
                                ForEach(job.faces.indices, id: \.self) { i in
                                    Toggle("Face \(i + 1)", isOn: Binding(get: { job.selected.contains(i) }, set: { _ in vm.toggle(jobID, face: i) }))
                                        .toggleStyle(.button)
                                }
                            }
                        }
                        Button("Re-swap this photo") { vm.reswap(jobID); dismiss() }
                            .buttonStyle(.borderedProminent).disabled(job.selected.isEmpty || vm.busy)
                    }
                    .padding()
                }
                .navigationTitle("Edit faces")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            }
        }
    }
}
