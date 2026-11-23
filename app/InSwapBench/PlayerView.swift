import AVFoundation
import CryptoKit
import MetalKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One FacePipeline (and one copy of the models in memory) shared by the Photo and Player tabs.
enum SharedPipeline {
    private static let lock = NSLock()
    private static var cached: [String: FacePipeline] = [:]
    /// `fast` = the 8-bit palettized swapper (only if installed; otherwise the FP16 one).
    static func get(fast: Bool = false) async throws -> FacePipeline {
        let name = fast && ModelStore.hasPal8 ? "swapper_pal8" : "swapper"
        if let c = lock.withLock({ cached[name] }) { return c }
        let p = try await Task.detached(priority: .userInitiated) { Box(v: try FacePipeline(modelsDirectory: ModelStore.dir, swapperName: name)) }.value.v
        lock.withLock { cached[name] = p }
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
    /// Swap strength for Mode A (VisoMaster style: 100 = 1 pass, 150 = 2 passes half-blended, 200 = 2, 300 = 3). Live preview always uses 1.
    @Published var strength: Int = { let v = UserDefaults.standard.integer(forKey: "strength"); return v == 0 ? 100 : v }() {
        didSet { UserDefaults.standard.set(strength, forKey: "strength"); if strength != oldValue, engine != nil { prepare() } }
    }
    /// 8-bit palettized swapper (63 ms vs 149 ms on the phone). Off until compared by eye; needs swapper_pal8 imported.
    @Published var fastSwapper: Bool = (UserDefaults.standard.object(forKey: "fastSwapper") as? Bool ?? true) && ModelStore.hasPal8 {   // default ON once installed (build 40 verified clean by the user)
        didSet { UserDefaults.standard.set(fastSwapper, forKey: "fastSwapper"); if fastSwapper != oldValue, engine != nil { prepare() } }
    }
    var costText: String {
        guard let e = engine else { return "" }
        let passes = (strength + 99) / 100
        let fps = 1 / max(0.001, e.reader.frameDuration.seconds)
        let minPerMin = fps / ((fastSwapper ? 15.0 : 6.5) / Double(passes))    // swaps/s on a cool phone (about 2.5 when hot)
        return String(format: "≈ %.1f min of rendering per minute of video on a cool phone", minPerMin)
    }
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var ranges: [ClosedRange<Double>] = []
    @Published var statsText = ""
    @Published var scrubbing = false
    let presenter = MetalPresenter()

    private var videoURL: URL?, sourceLatent: [Float]?, sourceEmbedding: [Float]?, sourceThumb: Data?
    private var timer: Timer?
    private var needsPrepare = false, logTick = 0
    private var active = true, visible = true
    @Published var diagnostics = ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    /// A temp file from Photos / Files: moved into the library (so it is counted and listed), then opened.
    func importVideo(_ url: URL, source: String) {
        status = "Importing video…"
        Task {
            if let e = await VideoStore.shared.importFile(url, title: "Video \(VideoStore.shared.entries.count + 1)", source: source) { setLibraryVideo(e) }
            else { status = VideoStore.shared.message }
        }
    }
    func setLibraryVideo(_ e: VideoLibrary.Entry) { AppLog.log("video opened (\(e.width)x\(e.height), \(Int(e.duration)) s, from \(e.source))", "player"); videoURL = VideoStore.shared.url(e); AppData.openVideoFile = e.file; prepare() }
    /// A source photo: detect, embed, derive the latent (also kept so it can be saved to the library).
    func setSource(_ data: Data) {
        AppLog.log("source photo picked \(data.count) bytes", "player")
        status = "Analysing source face…"
        Task {
            do {
                let pipe = try await SharedPipeline.get()
                let r = try await Task.detached(priority: .userInitiated) { Box(v: try FaceIngest.embed(photo: data, pipeline: pipe)) }.value.v
                sourceEmbedding = r.embedding; sourceThumb = r.thumb
                sourceLatent = pipe.latent(fromEmbeddings: [r.embedding])
                sourceImage = ImageFile.cgImage(data: data, maxSide: 200)
                prepare()
            } catch PipelineError.noFace { status = "No face found in the source photo." }
            catch { status = "Source failed: \(error.localizedDescription)" }
        }
    }
    /// A saved library face.
    func setLibraryFace(_ e: FaceLibrary.Entry) {
        Task {
            guard let pipe = try? await SharedPipeline.get(), let lat = FaceStore.shared.latent(id: e.id, pipeline: pipe) else { status = "Could not load that face."; return }
            AppLog.log("library face picked", "player")
            sourceLatent = lat; sourceEmbedding = nil; sourceThumb = nil
            sourceImage = FaceStore.shared.thumbnail(e.id)?.cgImage
            prepare()
        }
    }
    func saveSourceToLibrary() {
        guard let e = sourceEmbedding else { return }
        let n = FaceStore.shared.add(name: "Face \(FaceStore.shared.entries.count + 1)", embedding: e, thumb: sourceThumb)
        status = "Saved to library as \(n.name)."; sourceEmbedding = nil
    }

    private func prepare() {
        guard let url = videoURL else { return }
        guard let latent = sourceLatent else { status = "Video ready. Now pick a source face (photo or Library)."; return }
        if busy { needsPrepare = true; return }   // a pick made while loading is applied when this finishes
        busy = true
        engine?.shutdown(); engine = nil; timer?.invalidate()
        Task {
            defer { busy = false; if needsPrepare { needsPrepare = false; prepare() } }
            do {
                try? AVAudioSession.sharedInstance().setCategory(.playback)   // play through the silent switch
                try? AVAudioSession.sharedInstance().setActive(true)
                status = "Loading models (first load compiles for the Neural Engine and can take a while)…"
                let pipe = try await SharedPipeline.get(fast: fastSwapper)
                status = "Opening video…"
                let reader = try await VideoReader(url: url)
                let identity = "\(Self.videoID(url))|\(FaceLibrary.fingerprint(latent))|\(reader.width)x\(reader.height)|t2" + (strength == 100 ? "" : "|s\(strength)") + (fastSwapper && ModelStore.hasPal8 ? "|q8" : "")
                let dir = AppData.patchCacheRoot.appendingPathComponent(Self.hash(Data(identity.utf8)))
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                CacheManager.touch(dir)
                CacheManager.enforce(root: AppData.patchCacheRoot, capBytes: AppData.cacheCapBytes, keep: dir)
                let e = PlayerEngine(pipeline: pipe, reader: reader, latent: latent, strength: strength, cacheDirectory: dir, identity: identity)
                e.mode = mode; e.combo = combo
                duration = reader.duration; engine = e
                e.start()
                AppLog.log("engine ready: \(reader.width)x\(reader.height) \(reader.duration) s hdr \(reader.isHDR) mode \(mode.rawValue) combo \(combo) swapper \(fastSwapper && ModelStore.hasPal8 ? "8-bit" : "FP16") strength \(strength)", "player")
                status = "Ready. \(Int(reader.duration)) s, \(reader.width)×\(reader.height). Mode \(mode.rawValue), \(fastSwapper && ModelStore.hasPal8 ? "8-bit" : "FP16") swapper."
                startTimer()
            } catch PipelineError.noFace {
                status = "No face found in the source photo."
            } catch {
                AppLog.log("prepare FAILED: \(error)", "player")
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
        defer { logTick += 1; if logTick % 40 == 0 { AppLog.log(diagnostics.replacingOccurrences(of: "\n", with: " | "), "player") } }
        diagnostics = "build \(Self.build) · mode \(mode.rawValue)\(combo ? "+B" : "") · video \(e.reader.width)x\(e.reader.height) \(String(format: "%.1f", e.duration)) s · t=\(String(format: "%.2f", e.currentTime))\n"
            + statsText + "\npresented \(ps?.presented ?? 0), skipped \(ps?.skipped ?? 0) · ranges \(ranges.count) · retries \(s.retries)"
            + "\ndisplay: ticks \(e.dispTicks) new \(e.dispNew) noFrame \(e.dispNone) · drawable-nil \(DisplayStats.noDrawable) · no-texture/busy \(DisplayStats.presentFail) · gpu-errors \(ps?.gpuErrors ?? 0) (\(ps?.lastGPUError ?? "-"))\nframe \(e.frameSize) \(e.frameSample) · drawable \(ps?.lastDstSize ?? "-")\n\(e.itemInfo)"
            + "\nlast error: \(s.lastError ?? "none")\nstatus: \(status)"
    }

    var canSaveSource: Bool { sourceEmbedding != nil }
    /// Removes every cached render except the video currently open.
    func clearCache() {
        let keep = engine?.cacheDirectoryURL
        let freed = CacheManager.clear(root: AppData.patchCacheRoot, keep: keep)
        AppLog.log("cache cleared, freed \(freed / 1_000_000) MB", "player")
    }
    func togglePlay() { guard let e = engine else { return }; AppLog.log(e.isPlaying ? "pause" : "play", "player"); if e.isPlaying { e.pause() } else { e.play() }; playing = e.isPlaying }
    func scrub(_ t: Double) { time = t; engine?.scrub(to: t) }
    func endScrub() { AppLog.log("seek to \(String(format: "%.2f", time))", "player"); scrubbing = false; engine?.seek(to: time) }
    func setActive(_ a: Bool) { active = a; applyWork() }
    func setVisible(_ v: Bool) { visible = v; applyWork() }
    private func applyWork() {
        let on = active && visible
        AppLog.log("work \(on ? "on" : "paused") (active \(active), visible \(visible))", "player")
        engine?.workPaused = !on
        if !on { engine?.pause(); playing = false }
        UIApplication.shared.isIdleTimerDisabled = on && engine != nil
    }
    func teardown() { AppData.openVideoFile = nil; timer?.invalidate(); engine?.shutdown(); engine = nil; UIApplication.shared.isIdleTimerDisabled = false }

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
    static func cacheLine() -> String {
        let b = CacheManager.totalBytes(root: AppData.patchCacheRoot)
        return String(format: "Render cache %.0f MB (cap %.1f GB)", Double(b) / 1e6, Double(AppData.cacheCapBytes) / 1e9)
    }
    @StateObject private var vm = PlayerVM()
    @Environment(\.scenePhase) private var scenePhase
    @State private var videoItem: PhotosPickerItem?
    @State private var srcItem: PhotosPickerItem?
    @State private var importing = false
    @State private var showFaces = false
    @State private var showVideos = false
    @State private var cacheText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $videoItem, matching: .videos, preferredItemEncoding: .current) { Label("Video", systemImage: "film") }.lineLimit(1).fixedSize(horizontal: true, vertical: false).buttonStyle(.bordered)
                        Button { importing = true } label: { Label("File", systemImage: "folder") }.lineLimit(1).fixedSize(horizontal: true, vertical: false).buttonStyle(.bordered)
                        Button { showVideos = true } label: { Label("Saved", systemImage: "play.square.stack") }.lineLimit(1).fixedSize(horizontal: true, vertical: false).buttonStyle(.bordered)
                        PhotosPicker(selection: $srcItem, matching: .images) { Label("Source face", systemImage: "person.crop.square") }.lineLimit(1).fixedSize(horizontal: true, vertical: false).buttonStyle(.bordered)
                        Button { showFaces = true } label: { Label("Library", systemImage: "person.2") }.lineLimit(1).fixedSize(horizontal: true, vertical: false).buttonStyle(.bordered)
                        if let img = vm.sourceImage { Image(decorative: img, scale: 1).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(Circle()) }
                    }
                    if vm.canSaveSource { Button("Save this face to library") { vm.saveSourceToLibrary() }.font(.footnote) }
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
                    if ModelStore.hasPal8 { Toggle("Fast 8-bit swapper (on by default, 2.4x faster)", isOn: $vm.fastSwapper).font(.footnote) }
                    if vm.mode == .renderAhead {
                        Picker("Strength", selection: $vm.strength) {
                            Text("100").tag(100); Text("150").tag(150); Text("200").tag(200); Text("300").tag(300)
                        }.pickerStyle(.segmented)
                        Text("Strength \(vm.strength): \((vm.strength + 99) / 100) swap pass\(vm.strength > 100 ? "es" : ""). Higher may copy the source identity a little more strongly but renders slower; compare on a paused frame. \(vm.costText)").font(.caption).foregroundStyle(.secondary)
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
                    HStack {
                        Text(cacheText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear cache") { vm.clearCache(); cacheText = Self.cacheLine() }.buttonStyle(.bordered).font(.footnote)
                    }.onAppear { cacheText = Self.cacheLine() }
                }.padding()
            }
            .navigationTitle("Player")
        }
        .sheet(isPresented: $showVideos) { VideoLibrarySheet { vm.setLibraryVideo($0) } }
        .sheet(isPresented: $showFaces) { FacePickerSheet { vm.setLibraryFace($0) } }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task { if let m = try? await item.loadTransferable(type: MovieFile.self) { vm.importVideo(m.url, source: "Photos") } else { vm.status = "Could not load that video." } }
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
            do { try FileManager.default.copyItem(at: url, to: dst); vm.importVideo(dst, source: "Files") } catch { vm.status = "Could not open that file: \(error.localizedDescription)" }
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

enum DisplayStats { nonisolated(unsafe) static var noDrawable = 0, presentFail = 0, firstDrawable = true }

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
        private var lastKey: Int?
        @objc func tick() {
            // No GPU submissions unless the app is active (background submits fail with BackgroundExecutionNotPermitted).
            guard UIApplication.shared.applicationState == .active else { lastKey = nil; return }
            // Off screen (another tab) the layer can lose its content: forget what was drawn so the next visible tick redraws.
            guard let v0 = view, v0.window != nil, !v0.isHidden else { lastKey = nil; return }
            guard let view, let (frame, t) = engine.nextFrame(hostTime: CACurrentMediaTime()) else { return }
            let patches = engine.patches(at: t)
            // Skip redrawing an identical image (paused, no new patch): the layer keeps the last presented frame.
            var h = Hasher()
            h.combine(Int(bitPattern: Unmanaged.passUnretained(frame).toOpaque()))
            for p in patches { h.combine(p.M.tx); h.combine(p.M.ty); h.combine(p.M.a); h.combine(p.M.b); for v in p.bgr.prefix(48) { h.combine(v) } }
            let key = h.finalize()
            if key == lastKey { return }
            let layer = view.layer as? CAMetalLayer
            let want = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
            if let layer, layer.drawableSize != want { layer.drawableSize = want }   // layout can reset it to 0 (no drawable then)
            guard let drawable = layer?.nextDrawable() else {
                DisplayStats.noDrawable += 1
                if DisplayStats.noDrawable == 1 || DisplayStats.noDrawable % 200 == 0 {
                    AppLog.log("nextDrawable nil: layer \(layer == nil ? "NOT CAMetalLayer (\(type(of: view.layer)))" : "ok") drawableSize \(layer?.drawableSize ?? .zero) want \(want) bounds \(view.bounds.size) device \(layer?.device == nil ? "nil" : "set") fmt \(layer?.pixelFormat.rawValue ?? 0) window \(view.window == nil ? "nil" : "set") hidden \(view.isHidden)", "display")
                }
                return
            }
            if DisplayStats.firstDrawable { DisplayStats.firstDrawable = false; AppLog.log("first drawable \(drawable.texture.width)x\(drawable.texture.height)", "display") }
            if presenter.present(frame: frame, patches: patches, to: drawable.texture, drawable: drawable) { lastKey = key } else { DisplayStats.presentFail += 1 }
        }
    }
}
