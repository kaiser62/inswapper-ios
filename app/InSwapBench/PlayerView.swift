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
    let export = ExportSession()
    @Published var showExportSheet = false
    @Published var showExportProgress = false
    private var currentIdentity: String?

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
                currentIdentity = identity
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
    // MARK: export
    var swapperName: String { fastSwapper && ModelStore.hasPal8 ? "8-bit" : "FP16" }
    private var swapsPerSecond: Double { (fastSwapper && ModelStore.hasPal8 ? 15.0 : 6.5) / Double((strength + 99) / 100) }
    /// Computed once when the sheet opens (not on every VM tick).
    @Published var exportPlan: ExportEngine.Plan?
    private var exportPending = false
    func openExportSheet() {
        guard let e = engine else { return }
        exportPlan = ExportEngine(pipeline: e.pipeline, reader: e.reader, store: e.renderStore, latent: e.latent, strength: strength).plan()
        showExportSheet = true
    }
    /// Start was tapped: the export begins once the sheet has finished dismissing (a cover raised during a dismissal can be dropped).
    func requestExportStart() { exportPending = true }
    func sheetDismissed() { if exportPending { exportPending = false; startExport() } }
    var exportSwapsPerSecond: Double { swapsPerSecond }
    var exportFreeBytes: Int64 { VideoDownloader.freeBytes(at: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) }
    /// Shuts the Player engine down (two writers must never share the patch store) and hands everything to the export.
    func startExport() {
        guard let e = engine, let dir = e.cacheDirectoryURL, let id = currentIdentity else { return }
        let req = ExportRequest(pipeline: e.pipeline, reader: e.reader, latent: e.latent, strength: e.strength, cacheDirectory: dir, identity: id,
                                swapsPerSecond: swapsPerSecond, title: "export")
        timer?.invalidate(); e.shutdown(); engine = nil; playing = false
        showExportProgress = true
        export.start(req)
    }
    func endExport() { showExportProgress = false; export.reset(); prepare() }

    func setActive(_ a: Bool) { active = a; export.setActive(a); applyWork() }
    func setVisible(_ v: Bool) { visible = v; applyWork() }
    private func applyWork() {
        let on = active && visible
        AppLog.log("work \(on ? "on" : "paused") (active \(active), visible \(visible))", "player")
        engine?.workPaused = !on
        if !on { engine?.pause(); playing = false }
        UIApplication.shared.isIdleTimerDisabled = export.isRunning || (on && engine != nil)
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
        return String(format: "%.0f MB of %.1f GB", Double(b) / 1e6, Double(AppData.cacheCapBytes) / 1e9)
    }
    private enum Next { case none, files, saved, faces }
    @StateObject private var vm = PlayerVM()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var router: AppRouter
    @State private var videoItem: PhotosPickerItem?
    @State private var srcItem: PhotosPickerItem?
    @State private var importing = false
    @State private var showFaces = false
    @State private var showVideos = false
    @State private var showVideoSource = false
    @State private var showFaceSource = false
    @State private var showSettings = false
    @State private var next = Next.none
    @State private var cacheText = ""

    private var layoutState: PlayerLayoutState {
        var s = PlayerLayoutState()
        s.hasVideo = vm.engine != nil
        if let e = vm.engine {
            s.aspect = CGFloat(e.reader.width) / CGFloat(e.reader.height)
            s.videoDetail = "\(PlayerScrubber.clock(e.duration)) · \(e.reader.width)×\(e.reader.height)"
        }
        s.time = vm.time; s.duration = vm.duration; s.playing = vm.playing; s.ranges = vm.ranges
        s.badge = vm.engine == nil ? "" : "\(vm.swapperName) · \(vm.mode == .renderAhead ? "Render ahead" : "Live")"
        s.face = vm.sourceImage; s.status = vm.status; s.busy = vm.busy
        return s
    }

    private var actions: PlayerLayoutActions {
        PlayerLayoutActions(chooseVideo: { showVideoSource = true }, chooseFace: { showFaceSource = true },
                            togglePlay: { vm.togglePlay() }, export: { vm.openExportSheet() }, settings: { openSettings() },
                            scrub: { vm.scrub($0) }, scrubStart: { vm.scrubbing = true }, scrubEnd: { vm.endScrub() })
    }

    var body: some View {
        PlayerLayout(state: layoutState, mode: $vm.mode, actions: actions) {
            if let e = vm.engine, let pres = vm.presenter { MetalVideoView(engine: e, presenter: pres) }
        }
        .sheet(isPresented: $showVideoSource, onDismiss: runNext) {
            VideoSourceSheet(photosItem: $videoItem, onFiles: { next = .files; showVideoSource = false }, onSaved: { next = .saved; showVideoSource = false }).themed()
        }
        .sheet(isPresented: $showFaceSource, onDismiss: runNext) {
            FaceSourceSheet(photoItem: $srcItem, canSave: vm.canSaveSource, onLibrary: { next = .faces; showFaceSource = false }, onSave: { vm.saveSourceToLibrary() }).themed()
        }
        .sheet(isPresented: $showSettings) {
            PlayerSettingsSheet(fastSwapper: $vm.fastSwapper, strength: $vm.strength, combo: $vm.combo, hasFast: ModelStore.hasPal8,
                                costText: vm.costText, cacheText: cacheText, diagnostics: vm.diagnostics,
                                onClearCache: { vm.clearCache(); cacheText = Self.cacheLine() }, onCopyDiagnostics: { UIPasteboard.general.string = vm.diagnostics }).themed()
        }
        .sheet(isPresented: $vm.showExportSheet, onDismiss: { vm.sheetDismissed() }) {
            if let plan = vm.exportPlan {
                ExportSheet(plan: plan, duration: vm.duration, swapsPerSecond: vm.exportSwapsPerSecond, strength: vm.strength,
                            swapperName: vm.swapperName, freeBytes: vm.exportFreeBytes) { vm.requestExportStart() }.themed()
            }
        }
        .fullScreenCover(isPresented: $vm.showExportProgress) { ExportProgressView(session: vm.export) { vm.endExport() }.themed() }
        .sheet(isPresented: $showVideos) { VideoLibrarySheet { vm.setLibraryVideo($0) }.themed() }
        .sheet(isPresented: $showFaces) { FacePickerSheet { vm.setLibraryFace($0) }.themed() }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task { if let m = try? await item.loadTransferable(type: MovieFile.self) { vm.importVideo(m.url, source: "Photos") } else { vm.status = "Could not load that video." } }
        }
        .onChange(of: srcItem) { _, item in
            guard let item else { return }
            Task { if let d = try? await item.loadTransferable(type: Data.self) { vm.setSource(d) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .mpeg4Movie]) { result in importFile(result) }
        .onChange(of: router.pendingVideo) { _, e in
            if let e { vm.setLibraryVideo(e); router.pendingVideo = nil }   // the Library asked to open a saved video
        }
        .onChange(of: scenePhase) { _, phase in vm.setActive(phase == .active) }
        .onDisappear { vm.setVisible(false) }   // switching tabs pauses playback and the swap workers
        .onAppear { vm.setVisible(true) }
    }

    private func openSettings() { cacheText = Self.cacheLine(); showSettings = true }

    /// A source sheet asked for another picker: open it once the sheet has finished dismissing.
    private func runNext() {
        let n = next; next = .none
        switch n { case .files: importing = true; case .saved: showVideos = true; case .faces: showFaces = true; case .none: break }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(url.pathExtension)")
        do { try FileManager.default.copyItem(at: url, to: dst); vm.importVideo(dst, source: "Files") } catch { vm.status = "Could not open that file: \(error.localizedDescription)" }
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
