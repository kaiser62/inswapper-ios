import SwiftUI
import PhotosUI
import Photos

private struct Box<T>: @unchecked Sendable { let v: T }

@MainActor
final class PhotoVM: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var sourceImage: CGImage?
    @Published var targetImage: CGImage?
    @Published var targetFaces: [DetectedFace] = []
    @Published var selected: Set<Int> = []
    @Published var resultImage: CGImage?
    @Published var resultURL: URL?
    @Published var timings = "build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")\n"

    private var pipe: FacePipeline?
    private var srcBuf: CVPixelBuffer?
    private var tgtBuf: CVPixelBuffer?
    private var latent: [Float]?

    private func pipeline() async throws -> FacePipeline {
        if let p = pipe { return p }
        status = "Loading models (the first load compiles for the Neural Engine and can take a while)…"
        let t0 = Date()
        let p = try await Task.detached(priority: .userInitiated) {
            Box(v: try FacePipeline(modelsDirectory: ModelStore.dir))
        }.value.v
        pipe = p
        timings += String(format: "model load: %.0f ms\n", Date().timeIntervalSince(t0) * 1000)
        return p
    }

    func setSource(_ data: Data) {
        guard !busy else { return }
        busy = true; latent = nil; resultImage = nil
        Task {
            defer { busy = false }
            do {
                let p = try await pipeline()
                status = "Analysing source face…"
                let box = try await Task.detached(priority: .userInitiated) { () -> Box<(CVPixelBuffer, [Float])> in
                    let tl = Date()
                    let buf = try PixelBuf.load(data: data)
                    let loadMs = Date().timeIntervalSince(tl) * 1000
                    p.resetTimings()
                    p.addTiming("decode-image", loadMs)
                    guard let face = try p.detect(buf).max(by: { $0.area < $1.area }) else { throw PipelineError.noFace }
                    return Box(v: (buf, try p.latent(forSource: buf, face: face)))
                }.value
                srcBuf = box.v.0; latent = box.v.1
                sourceImage = PixelBuf.cgImage(from: box.v.0)
                timings += stageTimings(p, prefix: "source")
                status = "Source face ready."
            } catch PipelineError.noFace {
                sourceImage = nil; status = "No face found in the source photo."
            } catch {
                status = "Source failed: \(error.localizedDescription)"
            }
        }
    }

    func setTarget(_ data: Data) {
        guard !busy else { return }
        busy = true; resultImage = nil; targetFaces = []; selected = []
        Task {
            defer { busy = false }
            do {
                let p = try await pipeline()
                status = "Detecting faces…"
                let box = try await Task.detached(priority: .userInitiated) { () -> Box<(CVPixelBuffer, [DetectedFace])> in
                    let tl = Date()
                    let buf = try PixelBuf.load(data: data)
                    let loadMs = Date().timeIntervalSince(tl) * 1000
                    p.resetTimings()
                    p.addTiming("decode-image", loadMs)
                    return Box(v: (buf, try p.detect(buf)))
                }.value
                tgtBuf = box.v.0
                targetImage = PixelBuf.cgImage(from: box.v.0)
                targetFaces = box.v.1.sorted { $0.area > $1.area }
                selected = targetFaces.isEmpty ? [] : [0]
                timings += stageTimings(p, prefix: "target")
                status = targetFaces.isEmpty ? "No face found in the target photo." : "\(targetFaces.count) face(s) found. Largest is selected."
            } catch {
                status = "Target failed: \(error.localizedDescription)"
            }
        }
    }

    func swap() {
        guard !busy, let p = pipe, let lat = latent, let tgt = tgtBuf else { return }
        let faces = selected.sorted().map { targetFaces[$0] }
        guard !faces.isEmpty else { return }
        busy = true; status = "Swapping…"
        let tgtBox = Box(v: tgt), facesBox = Box(v: faces)
        Task {
            defer { busy = false }
            do {
                let t0 = Date()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("swapped-\(Int(Date().timeIntervalSince1970)).png")
                let box = try await Task.detached(priority: .userInitiated) { () -> Box<CGImage?> in
                    p.resetTimings()
                    let patches = try facesBox.v.map { try p.swap(frame: tgtBox.v, face: $0, latent: lat) }
                    let tc = Date()
                    let out = try Compositor.composite(tgtBox.v, patches: patches)
                    p.addTiming("composite", Date().timeIntervalSince(tc) * 1000)
                    let tp = Date()
                    try PixelBuf.writePNG(out, to: url)
                    p.addTiming("png", Date().timeIntervalSince(tp) * 1000)
                    let tg = Date()
                    let cg = PixelBuf.cgImage(from: out)
                    p.addTiming("cgimage", Date().timeIntervalSince(tg) * 1000)
                    return Box(v: cg)
                }.value
                resultImage = box.v; resultURL = url
                let (iw, ih) = PixelBuf.size(tgt)
                timings += stageTimings(p, prefix: "swap \(iw)x\(ih), \(faces.count) face(s)") + String(format: "swap total: %.0f ms\n", Date().timeIntervalSince(t0) * 1000)
                status = "Done."
            } catch {
                status = "Swap failed: \(error.localizedDescription)"
            }
        }
    }

    func saveToPhotos() {
        guard let url = resultURL else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in self.status = "Photos access denied (use Share instead)." }; return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }) { ok, err in
                Task { @MainActor in self.status = ok ? "Saved to Photos." : "Save failed: \(err?.localizedDescription ?? "unknown") (use Share instead)." }
            }
        }
    }

    private func stageTimings(_ p: FacePipeline, prefix: String) -> String {
        let parts = p.timings.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f", $0.key, $0.value) }
        return "\(prefix): " + parts.joined(separator: ", ") + " (ms)\n"
    }
}

struct PhotoView: View {
    @StateObject private var vm = PhotoVM()
    @State private var srcItem: PhotosPickerItem?
    @State private var tgtItem: PhotosPickerItem?
    @State private var installed = ModelStore.isInstalled

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
                        PhotosPicker(selection: $tgtItem, matching: .images) { Label("Target photo", systemImage: "photo") }
                            .buttonStyle(.bordered)
                    }
                    .disabled(vm.busy || !installed)
                    if let s = vm.sourceImage {
                        Image(decorative: s, scale: 1).resizable().scaledToFit().frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let t = vm.targetImage {
                        Image(decorative: t, scale: 1).resizable().scaledToFit()
                            .overlay(GeometryReader { geo in
                                let k = geo.size.width / CGFloat(t.width)
                                ForEach(vm.targetFaces.indices, id: \.self) { i in
                                    let f = vm.targetFaces[i]
                                    Rectangle().stroke(vm.selected.contains(i) ? Color.green : Color.white.opacity(0.7), lineWidth: 3)
                                        .frame(width: (f.x2 - f.x1) * k, height: (f.y2 - f.y1) * k)
                                        .position(x: (f.x1 + f.x2) / 2 * k, y: (f.y1 + f.y2) / 2 * k)
                                        .overlay(Text("\(i + 1)").font(.caption.bold()).padding(3).background(.black.opacity(0.6)).foregroundStyle(.white)
                                            .position(x: f.x1 * k + 10, y: f.y1 * k + 10))
                                }
                            })
                        if vm.targetFaces.count > 1 {
                            HStack {
                                ForEach(vm.targetFaces.indices, id: \.self) { i in
                                    Toggle("Face \(i + 1)", isOn: Binding(get: { vm.selected.contains(i) },
                                                                          set: { if $0 { vm.selected.insert(i) } else { vm.selected.remove(i) } }))
                                        .toggleStyle(.button)
                                }
                            }
                        }
                    }
                    if let r = vm.resultImage {
                        Text("Result (pick other faces above and tap Swap again)").font(.caption)
                        Image(decorative: r, scale: 1).resizable().scaledToFit()
                    }
                    Button("Swap") { vm.swap() }.buttonStyle(.borderedProminent)
                        .disabled(vm.busy || vm.selected.isEmpty || vm.sourceImage == nil)
                    if let url = vm.resultURL {
                        HStack {
                            ShareLink(item: url) { Label("Share / Save", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                            Button("Save to Photos") { vm.saveToPhotos() }.buttonStyle(.bordered)
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
        .onAppear { installed = ModelStore.isInstalled }
        .onChange(of: srcItem) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { vm.setSource(d) } }
        }
        .onChange(of: tgtItem) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { vm.setTarget(d) } }
        }
    }
}
