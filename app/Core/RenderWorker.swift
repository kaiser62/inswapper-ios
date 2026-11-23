import CoreVideo
import Foundation

/// Mode A background renderer: from a start time, swap every frame and store the patches. Run on a background thread.
/// One source latent, the largest face in each frame (multi-face policy comes later).
final class RenderWorker {
    let pipeline: FacePipeline, reader: VideoReader, store: PatchStore, latent: [Float]
    private(set) var framesDone = 0

    init(pipeline: FacePipeline, reader: VideoReader, store: PatchStore, latent: [Float]) {
        self.pipeline = pipeline; self.reader = reader; self.store = store; self.latent = latent
    }

    /// Blocks until `until` seconds (or the end), cancelled, or an error. Frames already in the store are skipped.
    func run(from start: Double, until: Double? = nil, cancel: CancelToken, gate: (() -> Void)? = nil, onFrame: ((Int64) -> Void)? = nil) throws {
        let endUs = until.map { PatchStore.us($0) }
        try reader.read(from: start) { frame, pts in
            gate?()   // pause / thermal throttle hook
            if cancel.isCancelled { return false }
            if let e = endUs, pts >= e { return false }
            if store.has(pts: pts) { return true }
            let face = try pipeline.detect(frame).max { $0.area < $1.area }
            if let f = face {
                store.put(pts: pts, [try pipeline.swap(frame: frame, face: f, latent: latent)])
            } else {
                store.put(pts: pts, [])
            }
            framesDone += 1
            onFrame?(pts)
            return true
        }
    }
}
