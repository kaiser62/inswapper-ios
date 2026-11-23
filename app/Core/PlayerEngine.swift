import AVFoundation
import Foundation

enum PlayMode: String { case renderAhead = "A", livePreview = "B" }

struct EngineStats { var swapsPerSecond = 0.0, latencyMs = 0.0, cachedFrames = 0, cacheMB = 0.0, thermal = ProcessInfo.ThermalState.nominal, lastError: String? = nil, retries = 0 }

/// The Phase 2 player brain (no UI types): AVPlayer = clock + audio, display frames pulled from an
/// AVPlayerItemVideoOutput (same upright/scaled video composition the swap reader uses, verified pixel-identical),
/// patches chosen per mode:
///  - A (renderAhead): RenderWorker swaps every frame from the playhead into `renderStore`; display uses the exact frame's patch.
///  - B (livePreview): LiveWorker swaps ahead of the playhead; display pastes the newest patch at its own M.
///  - combo: A, with B filling frames A has not rendered yet.
final class PlayerEngine {
    let pipeline: FacePipeline, reader: VideoReader, latent: [Float]
    let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    let renderStore: PatchStore, liveStore: PatchStore
    private let cacheDirectory: URL?
    private let lock = NSLock()
    private var _mode = PlayMode.livePreview, _combo = false, _paused = false
    private var renderToken = CancelToken(), liveToken = CancelToken()
    private let renderQueue = DispatchQueue(label: "engine.render", qos: .userInitiated)
    private let liveQueue = DispatchQueue(label: "engine.live", qos: .userInitiated)
    private var liveWorker: LiveWorker?
    private var lastFrame: (CVPixelBuffer, Double)?
    private var windowStart = Date(), windowCount = 0, rate = 0.0
    private(set) var lastError: String?
    private var retries = 0, lastTick = Date.distantPast
    /// Display diagnostics (read by the UI): ticks asked for a frame, frames that were new, ticks with no frame at all.
    private(set) var dispTicks = 0, dispNew = 0, dispNone = 0
    var itemInfo: String {
        guard let it = player.currentItem else { return "no item" }
        let st = ["unknown", "ready", "FAILED"][min(2, it.status.rawValue)]
        return "item \(st)\(it.error.map { " (\($0.localizedDescription))" } ?? "") · size \(Int(it.presentationSize.width))x\(Int(it.presentationSize.height)) · hdr \(reader.isHDR)"
    }

    init(pipeline: FacePipeline, reader: VideoReader, latent: [Float], cacheDirectory: URL?, identity: String) {
        self.pipeline = pipeline; self.reader = reader; self.latent = latent; self.cacheDirectory = cacheDirectory
        renderStore = PatchStore(frameDurationUs: reader.frameDurationUs)
        liveStore = PatchStore(frameDurationUs: reader.frameDurationUs)
        if let d = cacheDirectory { renderStore.attach(directory: d, identity: identity) }
        let item = AVPlayerItem(asset: reader.asset)
        item.videoComposition = reader.composition
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                 kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
    }

    // MARK: transport
    var currentTime: Double { player.currentTime().seconds }
    var duration: Double { reader.duration }
    var isPlaying: Bool { player.rate != 0 }
    func play() { player.play() }
    func pause() { player.pause(); renderStore.flush() }

    /// While dragging a scrubber: move the playhead only (raw frames; workers keep going, restart happens on `seek`).
    func scrub(to t: Double) {
        player.seek(to: CMTime(seconds: min(max(0, t), max(0, duration - 0.05)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to t: Double) {
        let c = min(max(0, t), max(0, duration - 0.05))
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        liveStore.removeAll()
        if mode == .renderAhead { restartRender(from: c) }
        // Mode B's worker notices the playhead jump by itself and restarts its reader.
    }

    // MARK: modes
    var mode: PlayMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock(); applyMode() }
    }
    var combo: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _combo }
        set { lock.lock(); _combo = newValue; lock.unlock(); applyMode() }
    }
    /// App in background / user pause of swapping work.
    var workPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock(); if newValue { renderStore.flush() } }
    }

    func start() { applyMode() }

    func shutdown() {
        renderToken.cancel(); liveToken.cancel(); player.pause(); renderStore.flush()
    }

    private func applyMode() {
        let m = mode, c = combo
        pipeline.cpuDetector = c   // two workers swapping at once: detect on CPU so the ANE stays with the swapper
        if m == .renderAhead { restartRender(from: currentTime) } else { renderToken.cancel() }
        if m == .livePreview || c { startLive() } else { liveToken.cancel(); liveStore.removeAll() }
    }

    private func gate() {
        while workPaused || ProcessInfo.processInfo.thermalState == .critical { Thread.sleep(forTimeInterval: 0.2); if renderToken.isCancelled && liveToken.isCancelled { return } }
        if ProcessInfo.processInfo.thermalState == .serious { Thread.sleep(forTimeInterval: 0.15) }
    }
    private func tick() { lock.lock(); windowCount += 1; lastTick = Date()
        let dt = Date().timeIntervalSince(windowStart)
        if dt >= 2 { rate = Double(windowCount) / dt; windowCount = 0; windowStart = Date() }
        lock.unlock() }

    private func restartRender(from t: Double) {
        renderToken.cancel()
        let token = CancelToken(); renderToken = token
        let worker = RenderWorker(pipeline: pipeline, reader: reader, store: renderStore, latent: latent)
        renderQueue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            var attempts = 0, sinceFlush = 0, from = t
            while !token.isCancelled {
                do {
                    try worker.run(from: from, cancel: token, gate: { self.gate() }, onFrame: { _ in
                        self.tick(); sinceFlush += 1
                        if sinceFlush >= Int(PatchStore.chunkFrames) { sinceFlush = 0; self.renderStore.flush() }   // a kill loses < 1 chunk
                    })
                    break
                } catch {
                    // e.g. the asset reader failing after a background excursion: note it, retry from the playhead
                    self.noteError("render: \(error)"); attempts += 1
                    if attempts > 5 { break }
                    Thread.sleep(forTimeInterval: 1); from = self.currentTime
                }
            }
            self.renderStore.flush()
        }
    }

    private func startLive() {
        liveToken.cancel()
        let token = CancelToken(); liveToken = token
        let worker = LiveWorker(pipeline: pipeline, reader: reader, store: liveStore, latent: latent)
        liveWorker = worker
        liveQueue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            var attempts = 0
            while !token.isCancelled {
                do {
                    try worker.run(playhead: { self.player.currentTime().seconds }, cancel: token, gate: { self.gate() }, onPatch: { _ in
                        if self.mode == .livePreview { self.tick() } })
                    break
                } catch {
                    self.noteError("live: \(error)"); attempts += 1
                    if attempts > 5 { break }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }

    private func noteError(_ e: String) { lock.lock(); lastError = e; retries += 1; lock.unlock() }

    // MARK: display
    /// The frame to draw now (the newest decoded frame; the previous one if none is new) and its display time in seconds.
    func nextFrame(hostTime: CFTimeInterval) -> (frame: CVPixelBuffer, time: Double)? {
        let it = output.itemTime(forHostTime: hostTime)
        lock.lock(); dispTicks += 1; lock.unlock()
        if it.isValid, output.hasNewPixelBuffer(forItemTime: it), let pb = output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil) {
            lock.lock(); dispNew += 1; lock.unlock()
            lastFrame = (pb, it.seconds)
        } else if lastFrame == nil, let pb = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            lastFrame = (pb, player.currentTime().seconds)
        } else if lastFrame != nil { lastFrame!.1 = it.isValid ? it.seconds : lastFrame!.1 }
        if lastFrame == nil { lock.lock(); dispNone += 1; lock.unlock() }
        return lastFrame.map { ($0.0, $0.1) }
    }

    /// Patches to paste on the frame shown at `time` (seconds).
    func patches(at time: Double) -> [SwapPatch] {
        let us = PatchStore.us(time)
        switch mode {
        case .renderAhead:
            if let p = renderStore.get(displayedAt: us) { return p }
            return combo ? (liveStore.latest(atOrBefore: us) ?? []) : []
        case .livePreview:
            return liveStore.latest(atOrBefore: us) ?? []
        }
    }

    func renderedRanges() -> [ClosedRange<Double>] { renderStore.renderedRanges().map { (Double($0.lowerBound) / 1e6)...(Double($0.upperBound) / 1e6) } }

    /// Memory pressure / long renders: keep RAM bounded (disk keeps everything).
    func trimMemory(maxMB: Int = 300) { renderStore.evict(maxBytes: maxMB * 1_000_000, keepNear: PatchStore.us(currentTime)) }

    var stats: EngineStats {
        lock.lock(); defer { lock.unlock() }
        let live = Date().timeIntervalSince(lastTick) < 3   // no swap for 3 s: report 0, not the stale last rate
        return EngineStats(swapsPerSecond: live ? rate : 0, latencyMs: (liveWorker?.latency ?? 0) * 1000, cachedFrames: renderStore.count,
                           cacheMB: Double(renderStore.bytes) / 1e6, thermal: ProcessInfo.processInfo.thermalState, lastError: lastError, retries: retries)
    }
}
