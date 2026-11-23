import Foundation
import Photos
import UIKit

/// Everything an export needs, captured from the Player at the moment the user taps Start.
struct ExportRequest {
    let pipeline: FacePipeline, reader: VideoReader, latent: [Float], strength: Int
    let cacheDirectory: URL, identity: String
    let swapsPerSecond: Double
    let title: String
}

/// Thread-safe pause / cancel / app-active flags shared with the export thread.
private final class ExportControl {
    let cancel = CancelToken()
    private let lock = NSLock()
    private var _paused = false, _active = true
    var paused: Bool { get { lock.withLock { _paused } } set { lock.withLock { _paused = newValue } } }
    var active: Bool { get { lock.withLock { _active } } set { lock.withLock { _active = newValue } } }
    /// Blocks while paused, inactive or critically hot; returns when cancelled.
    func gate() {
        while !cancel.isCancelled, paused || !active || ProcessInfo.processInfo.thermalState == .critical { Thread.sleep(forTimeInterval: 0.2) }
    }
}

/// Runs one export on a background thread and publishes its progress for the UI.
@MainActor
final class ExportSession: ObservableObject {
    enum State: Equatable { case idle, running, done(URL), failed(String), cancelled }

    @Published private(set) var state = State.idle
    @Published private(set) var phase = ExportEngine.Phase.rendering
    @Published private(set) var done = 0
    @Published private(set) var total = 1
    @Published private(set) var secondsLeft: Double?
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var paused = false
    @Published private(set) var saveMessage: String?

    private var control = ExportControl()
    private var windowStart = Date(), windowDone = 0, windowPhase = ExportEngine.Phase.rendering
    private var renderRate = 0.0
    private var request: ExportRequest?
    private var windowSeeded = false
    private var thermalTimer: Timer?

    var isRunning: Bool { state == .running }
    /// 0...1 within the current phase.
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    static var exportsDirectory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func start(_ r: ExportRequest) {
        guard !isRunning else { return }
        request = r; control = ExportControl(); paused = false; saveMessage = nil; secondsLeft = nil
        phase = .rendering; done = 0; total = max(1, ExportEngine.estimatedFrames(reader: r.reader)); renderRate = 0
        windowStart = Date(); windowDone = 0; windowPhase = .rendering; windowSeeded = false
        thermalTimer?.invalidate()
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.thermal = ProcessInfo.processInfo.thermalState }
        }
        state = .running
        UIApplication.shared.isIdleTimerDisabled = true
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let out = Self.exportsDirectory.appendingPathComponent("InSwap-\(f.string(from: Date())).mp4")
        let c = control
        AppLog.log("export start: \(r.reader.width)x\(r.reader.height) \(Int(r.reader.duration)) s strength \(r.strength)", "export")
        Thread.detachNewThread { [weak self] in
            do {
                // the Player engine was shut down just before; give its last flush a moment so two writers never overlap
                Thread.sleep(forTimeInterval: 1.0)
                let store = PatchStore(frameDurationUs: r.reader.frameDurationUs)
                store.attach(directory: r.cacheDirectory, identity: r.identity)
                let engine = ExportEngine(pipeline: r.pipeline, reader: r.reader, store: store, latent: r.latent, strength: r.strength)
                // leaving the app can kill the asset reader / HEVC writer: wait until active again and resume (rendered frames are kept)
                var attempt = 0
                while true {
                    do {
                        try engine.run(to: out, cancel: c.cancel, gate: { c.gate() }, progress: { p in
                            Task { @MainActor in self?.apply(p) }
                        })
                        break
                    } catch let e as ExportEngine.ExportError {
                        switch e { case .cancelled, .noSpace: throw e; default: break }
                        attempt += 1; AppLog.log("export error (attempt \(attempt)): \(e)", "export")
                        if attempt >= 3 { throw e }
                        c.gate(); Thread.sleep(forTimeInterval: 1)
                        if c.cancel.isCancelled { throw ExportEngine.ExportError.cancelled }
                        Task { @MainActor in self?.restartWindow() }
                    } catch {
                        attempt += 1; AppLog.log("export error (attempt \(attempt)): \(error)", "export")
                        if attempt >= 3 { throw error }
                        c.gate(); Thread.sleep(forTimeInterval: 1)
                        if c.cancel.isCancelled { throw ExportEngine.ExportError.cancelled }
                        Task { @MainActor in self?.restartWindow() }
                    }
                }
                Task { @MainActor in self?.finish(.done(out)) }
            } catch ExportEngine.ExportError.cancelled {
                Task { @MainActor in self?.finish(.cancelled) }
            } catch {
                Task { @MainActor in self?.finish(.failed(error.localizedDescription)) }
            }
        }
    }

    private func finish(_ s: State) {
        UIApplication.shared.isIdleTimerDisabled = false
        thermalTimer?.invalidate(); thermalTimer = nil
        AppLog.log("export finished: \(s)", "export")
        state = s
    }

    private func apply(_ p: ExportEngine.Progress) {
        guard isRunning else { return }
        thermal = ProcessInfo.processInfo.thermalState
        if !windowSeeded { windowSeeded = true; windowStart = Date(); windowDone = p.done }   // frames already on disk are not progress
        if p.phase != windowPhase { windowPhase = p.phase; windowStart = Date(); windowDone = p.done }
        phase = p.phase; done = p.done; total = max(1, p.total)
        let dt = Date().timeIntervalSince(windowStart), dn = p.done - windowDone
        if dt > 3, dn > 4 {
            let rate = Double(dn) / dt
            if p.phase == .rendering { renderRate = rate }
            let left = Double(total - p.done) / rate
            // while rendering, the encode pass that follows is cheap (about 120 frames/s)
            secondsLeft = p.phase == .rendering ? left + Double(total) / 120 : left
        }
    }

    /// CI screenshots only (ExportPreview): put the session in a fixed state without running anything.
    func debugSet(_ s: State, phase: ExportEngine.Phase, done: Int, total: Int, secondsLeft: Double?, thermal: ProcessInfo.ThermalState, paused: Bool = false) {
        state = s; self.phase = phase; self.done = done; self.total = total; self.secondsLeft = secondsLeft; self.thermal = thermal; self.paused = paused
    }
    func restartWindow() { windowStart = Date(); windowDone = done; secondsLeft = nil }
    func setPaused(_ p: Bool) {
        paused = p; control.paused = p
        windowStart = Date(); windowDone = done; secondsLeft = nil   // restart the rate window after a pause
    }
    func setActive(_ a: Bool) { control.active = a; windowStart = Date(); windowDone = done }
    func cancel() { control.cancel.cancel() }
    func reset() { state = .idle; saveMessage = nil }

    func saveToPhotos(_ url: URL) {
        Task {
            let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard st == .authorized || st == .limited else { saveMessage = "Photos access was not granted. The video is kept in the app's Exports folder; use Share to send it elsewhere."; return }
            do {
                try await PHPhotoLibrary.shared().performChanges { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                saveMessage = "Saved to Photos."
            } catch { saveMessage = "Could not save to Photos (\(error.localizedDescription)). The file is kept; use Share." }
        }
    }
}
