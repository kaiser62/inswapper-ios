import AVFoundation
import CryptoKit
import MetalKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One FacePipeline (and one copy of the models in memory) shared by the Photo and Player tabs.
enum SharedPipeline {
    private static let lock = NSLock()
    private static var cached: FacePipeline?
    static func get() async throws -> FacePipeline {
        if let p = lock.withLock({ cached }) { return p }
        let p = try await Task.detached(priority: .userInitiated) { Box(v: try FacePipeline(modelsDirectory: ModelStore.dir)) }.value.v
        lock.withLock { cached = p }
        return p
    }
}

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return MovieFile(url: dst)
        }
    }
}

@MainActor
final class PlayerVM: ObservableObject {
    @Published var status = "Pick a video and a source face."
    @Published var busy = false
    @Published var engine: PlayerEngine?
    @Published var sourceImage: CGImage?
    @Published var mode = PlayMode.livePreview { didSet { engine?.mode = mode } }
    @Published var combo = false { didSet { engine?.combo = combo } }
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var ranges: [ClosedRange<Double>] = []
    @Published var statsText = ""
    @Published var scrubbing = false
    let presenter = MetalPresenter()

    private var videoURL: URL?, sourceData: Data?
    private var timer: Timer?
    private var needsPrepare = false
    private var active = true, visible = true
    @Published var diagnostics = ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    func setVideo(_ url: URL) { videoURL = url; prepare() }
    func setSource(_ data: Data) { sourceData = data; sourceImage = ImageFile.cgImage(data: data, maxSide: 200); prepare() }

    private func prepare() {
        guard let url = videoURL, let data = sourceData else { return }
        if busy { needsPrepare = true; return }   // a pick made while loading is applied when this finishes
        busy = true
        engine?.shutdown(); engine = nil; timer?.invalidate()
        Task {
            defer { busy = false; if needsPrepare { needsPrepare = false; prepare() } }
            do {
                try? AVAudioSession.sharedInstance().setCategory(.playback)   // play through the silent switch
                try? AVAudioSession.sharedInstance().setActive(true)
                status = "Loading models (first load compiles for the Neural Engine and can take a while)…"
                let pipe = try await SharedPipeline.get()
                status = "Analysing source face…"
                let latent = try await Task.detached(priority: .userInitiated) { () -> Box<[Float]> in
                    let buf = try PixelBuf.load(data: data)
                    guard let f = try pipe.detect(buf).max(by: { $0.area < $1.area }) else { throw PipelineError.noFace }
                    return Box(v: try pipe.latent(forSource: buf, face: f))
                }.value.v
                status = "Opening video…"
                let reader = try await VideoReader(url: url)
                let identity = "\(Self.videoID(url))|\(Self.hash(data))|\(reader.width)x\(reader.height)"
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("patchcache/\(Self.hash(Data(identity.utf8)))")
                let e = PlayerEngine(pipeline: pipe, reader: reader, latent: latent, cacheDirectory: dir, identity: identity)
                e.mode = mode; e.combo = combo
                duration = reader.duration; engine = e
                e.start()
                status = "Ready. \(Int(reader.duration)) s, \(reader.width)×\(reader.height). Mode \(mode.rawValue)."
                startTimer()
            } catch PipelineError.noFace {
                status = "No face found in the source photo."
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard let e = engine else { return }
        if !scrubbing { time = e.currentTime }
        playing = e.isPlaying
        ranges = e.renderedRanges()
        let s = e.stats
        e.trimMemory()
        statsText = String(format: "%.1f swaps/s · latency %.0f ms · cached %d frames (%.0f MB) · thermal %@",
                           s.swapsPerSecond, s.latencyMs, s.cachedFrames, s.cacheMB, Self.thermalName(s.thermal))
        let ps = presenter
        diagnostics = "build \(Self.build) · mode \(mode.rawValue)\(combo ? "+B" : "") · video \(e.reader.width)x\(e.reader.height) \(String(format: "%.1f", e.duration)) s · t=\(String(format: "%.2f", e.currentTime))\n"
            + statsText + "\npresented \(ps?.presented ?? 0), skipped \(ps?.skipped ?? 0) · ranges \(ranges.count) · retries \(s.retries)"
            + "\ndisplay: ticks \(e.dispTicks) new \(e.dispNew) noFrame \(e.dispNone) · drawable-nil \(DisplayStats.noDrawable) · gpu-fail \(DisplayStats.presentFail)\n\(e.itemInfo)"
            + "\nlast error: \(s.lastError ?? "none")\nstatus: \(status)"
    }

    func togglePlay() { guard let e = engine else { return }; if e.isPlaying { e.pause() } else { e.play() }; playing = e.isPlaying }
    func scrub(_ t: Double) { time = t; engine?.scrub(to: t) }
    func endScrub() { scrubbing = false; engine?.seek(to: time) }
    func setActive(_ a: Bool) { active = a; applyWork() }
    func setVisible(_ v: Bool) { visible = v; applyWork() }
    private func applyWork() {
        let on = active && visible
        engine?.workPaused = !on
        if !on { engine?.pause(); playing = false }
        UIApplication.shared.isIdleTimerDisabled = on && engine != nil
    }
    func teardown() { timer?.invalidate(); engine?.shutdown(); engine = nil; UIApplication.shared.isIdleTimerDisabled = false }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s { case .nominal: return "nominal"; case .fair: return "fair"; case .serious: return "SERIOUS"; case .critical: return "CRITICAL"; @unknown default: return "?" }
    }
    static func hash(_ d: Data) -> String { String(SHA256.hash(data: d.prefix(1 << 20)).map { String(format: "%02x", $0) }.joined().prefix(24)) }
    static func videoID(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var head = Data()
        if let h = try? FileHandle(forReadingFrom: url) { head = (try? h.read(upToCount: 1 << 18)) ?? Data(); try? h.close() }
        return "\(size)-\(hash(head))"
    }
}

struct PlayerView: View {
    @StateObject private var vm = PlayerVM()
    @Environment(\.scenePhase) private var scenePhase
    @State private var videoItem: PhotosPickerItem?
    @State private var srcItem: PhotosPickerItem?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        PhotosPicker(selection: $videoItem, matching: .videos, preferredItemEncoding: .current) { Label("Video", systemImage: "film") }.buttonStyle(.bordered)
                        Button { importing = true } label: { Label("File", systemImage: "folder") }.buttonStyle(.bordered)
                        PhotosPicker(selection: $srcItem, matching: .images) { Label("Source face", systemImage: "person.crop.square") }.buttonStyle(.bordered)
                        if let img = vm.sourceImage { Image(decorative: img, scale: 1).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(Circle()) }
                    }
                    Text(vm.status).font(.footnote).foregroundStyle(.secondary)
                    if let e = vm.engine, let pres = vm.presenter {
                        MetalVideoView(engine: e, presenter: pres)
                            .aspectRatio(CGFloat(e.reader.width) / CGFloat(e.reader.height), contentMode: .fit)
                            .background(Color.black)
                        controls
                    }
                    Picker("Mode", selection: $vm.mode) {
                        Text("A  Render ahead").tag(PlayMode.renderAhead)
                        Text("B  Live preview").tag(PlayMode.livePreview)
                    }.pickerStyle(.segmented)
                    if vm.mode == .renderAhead {
                        Toggle("A + B fallback (live preview where not rendered yet)", isOn: $vm.combo).font(.footnote)
                        Text("A swaps every frame from the playhead in the background (about 3-5 min of work per minute of video) and shows the green parts of the bar fully swapped. Unrendered parts play raw. Cached on disk per video and face.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("B shows the current frame with the newest swapped face (about 6-8 updates/s, timed ahead of the playhead). Instant after any seek; the face lags on fast motion.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !vm.diagnostics.isEmpty {
                        Text(vm.diagnostics).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Copy diagnostics") { UIPasteboard.general.string = vm.diagnostics }.buttonStyle(.bordered).font(.footnote)
                    }
                }.padding()
            }
            .navigationTitle("Player")
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task { if let m = try? await item.loadTransferable(type: MovieFile.self) { vm.setVideo(m.url) } else { vm.status = "Could not load that video." } }
        }
        .onChange(of: srcItem) { _, item in
            guard let item else { return }
            Task { if let d = try? await item.loadTransferable(type: Data.self) { vm.setSource(d) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .mpeg4Movie]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(url.pathExtension)")
            do { try FileManager.default.copyItem(at: url, to: dst); vm.setVideo(dst) } catch { vm.status = "Could not open that file: \(error.localizedDescription)" }
        }
        .onChange(of: scenePhase) { _, phase in vm.setActive(phase == .active) }
        .onDisappear { vm.setVisible(false) }   // switching tabs pauses playback and the swap workers
        .onAppear { vm.setVisible(true) }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                GeometryReader { g in
                    ForEach(Array(vm.ranges.enumerated()), id: \.offset) { _, r in
                        let w = g.size.width, d = max(vm.duration, 0.001)
                        Rectangle().fill(Color.green.opacity(0.55))
                            .frame(width: max(2, w * (r.upperBound - r.lowerBound) / d), height: 6)
                            .offset(x: w * r.lowerBound / d, y: g.size.height / 2 - 3)
                    }
                }.frame(height: 28)
                Slider(value: Binding(get: { vm.time }, set: { vm.scrub($0) }), in: 0...max(vm.duration, 0.1)) { editing in
                    if editing { vm.scrubbing = true } else { vm.endScrub() }
                }
            }
            HStack {
                Button { vm.togglePlay() } label: { Image(systemName: vm.playing ? "pause.fill" : "play.fill").font(.title2) }
                Text(String(format: "%d:%02d / %d:%02d", Int(vm.time) / 60, Int(vm.time) % 60, Int(vm.duration) / 60, Int(vm.duration) % 60))
                    .font(.system(.footnote, design: .monospaced))
                Spacer()
            }
        }
    }
}

enum DisplayStats { @MainActor static var noDrawable = 0, presentFail = 0 }

struct MetalVideoView: UIViewRepresentable {
    let engine: PlayerEngine
    let presenter: MetalPresenter

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, presenter: presenter) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: presenter.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false          // the compute kernel writes into the drawable
        v.isPaused = true; v.enableSetNeedsDisplay = false
        v.autoResizeDrawable = false
        v.drawableSize = CGSize(width: engine.reader.width, height: engine.reader.height)
        v.layer.contentsGravity = .resizeAspect
        context.coordinator.start(view: v)
        return v
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject {
        let engine: PlayerEngine, presenter: MetalPresenter
        private var link: CADisplayLink?
        private weak var view: MTKView?
        init(engine: PlayerEngine, presenter: MetalPresenter) { self.engine = engine; self.presenter = presenter }
        func start(view: MTKView) {
            self.view = view
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
        }
        func stop() { link?.invalidate(); link = nil }
        @objc func tick() {
            guard let view, let (frame, t) = engine.nextFrame(hostTime: CACurrentMediaTime()) else { return }
            guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else { DisplayStats.noDrawable += 1; return }
            if !presenter.present(frame: frame, patches: engine.patches(at: t), to: drawable.texture, drawable: drawable) { DisplayStats.presentFail += 1 }
        }
    }
}
