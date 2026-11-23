import CoreVideo
import Foundation

/// Mode B: reduced-rate live preview. Follows a playhead: repeatedly swaps the frame at (playhead + measured pipeline
/// latency) so the patch arrives roughly when the playhead reaches that frame. Results go into `store` (the player pastes
/// `store.latest(atOrBefore:)` onto the raw frame at its own M). One sequential reader; frames behind the target are
/// skipped (decode only), and the reader restarts when the playhead jumps (seek) or runs far ahead.
final class LiveWorker {
    let pipeline: FacePipeline, reader: VideoReader, store: PatchStore, latent: [Float]
    private let lock = NSLock()
    private var _latency = 0.16
    /// Smoothed detect+swap+bookkeeping time in seconds (starts at the ~160 ms device estimate).
    var latency: Double { lock.lock(); defer { lock.unlock() }; return _latency }
    private(set) var swaps = 0

    init(pipeline: FacePipeline, reader: VideoReader, store: PatchStore, latent: [Float]) {
        self.pipeline = pipeline; self.reader = reader; self.store = store; self.latent = latent
    }

    /// Blocks until cancelled. `playhead` returns the current playback time in seconds (thread-safe).
    func run(playhead: () -> Double, cancel: CancelToken, gate: (() -> Void)? = nil, onPatch: ((Int64) -> Void)? = nil) throws {
        while !cancel.isCancelled {
            let begin = max(0, playhead() + latency)
            var ranToEnd = true
            try reader.read(from: begin) { frame, pts in
                if cancel.isCancelled { ranToEnd = false; return false }
                // Never swap a frame before it is due (frozen/slow playhead => idle, not full load); restart on a seek.
                while true {
                    if cancel.isCancelled { ranToEnd = false; return false }
                    let ph = PatchStore.us(playhead()), target = ph + PatchStore.us(latency)
                    if pts > target + 750_000 || pts < ph - 750_000 { ranToEnd = false; return false }  // seek: restart
                    if pts < target - reader.frameDurationUs / 2 { return true }                          // behind: skip (decode only)
                    if pts <= target + reader.frameDurationUs / 2 { break }                               // due now
                    Thread.sleep(forTimeInterval: 0.01)                                                   // ahead: wait
                }
                gate?()
                if cancel.isCancelled { ranToEnd = false; return false }
                let t0 = Date()
                let face = try pipeline.detect(frame).max { $0.area < $1.area }
                store.put(pts: pts, face.map { [try? pipeline.swap(frame: frame, face: $0, latent: latent)].compactMap { $0 } } ?? [])
                let dt = Date().timeIntervalSince(t0)
                lock.lock(); _latency = 0.7 * _latency + 0.3 * (dt + 0.01); lock.unlock()
                swaps += 1
                store.evict(maxBytes: 16 * (128 * 128 * 3 + 64), keepNear: pts)
                onPatch?(pts)
                return true
            }
            if ranToEnd { // video ended: wait for the playhead to move away or cancel
                while !cancel.isCancelled && PatchStore.us(playhead()) >= PatchStore.us(reader.duration) - reader.frameDurationUs { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
    }
}
