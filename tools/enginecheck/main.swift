// Mac harness for the Phase 2 engine: VideoReader + RenderWorker + PatchStore on the local stock clips (local only).
// Usage: build/enginecheck tools/models <clip.mp4> [startSec] [seconds]
import CoreML
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let test = root.appendingPathComponent("test"), compiled = root.appendingPathComponent("compiled")
let clip = URL(fileURLWithPath: CommandLine.arguments[2])
let start = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 0
let secs = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4])! : 3

func main() async throws {
    let pipe = try FacePipeline(modelsDirectory: compiled)
    let src = try PixelBuf.load(url: test.appendingPathComponent("source.jpeg"))
    let sf = try pipe.detect(src).max { $0.area < $1.area }!
    let lat = try pipe.latent(forSource: src, face: sf)
    let reader = try await VideoReader(url: clip, maxLongSide: 1280)
    print("video \(reader.width)x\(reader.height) dur \(reader.duration)s frameDur \(reader.frameDurationUs)us")
    let store = PatchStore(frameDurationUs: reader.frameDurationUs)
    let worker = RenderWorker(pipeline: pipe, reader: reader, store: store, latent: lat)
    let t0 = Date()
    try worker.run(from: start, until: start + secs, cancel: CancelToken())
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "rendered %d frames in %.1fs = %.2f swaps/s", worker.framesDone, dt, Double(worker.framesDone) / dt))
    print("ranges (s):", store.renderedRanges().map { String(format: "%.2f-%.2f", Double($0.lowerBound) / 1e6, Double($0.upperBound) / 1e6) })
    // re-run same window: all skipped
    let t1 = Date(); let before = worker.framesDone
    try worker.run(from: start, until: start + secs, cancel: CancelToken())
    print(String(format: "re-run skipped %d new frames in %.2fs", worker.framesDone - before, Date().timeIntervalSince(t1)))
    // composite first, middle, last stored frame onto raw frames
    var want = Set([start, start + secs / 2, start + secs - 0.1].map { PatchStore.us($0) })
    var idx = 0
    try reader.read(from: start) { f, pts in
        guard let k = want.first(where: { abs($0 - pts) <= reader.frameDurationUs / 2 }) else { return pts < PatchStore.us(start + secs) }
        want.remove(k)
        let p = store.get(pts: pts) ?? []
        let out = try Compositor.composite(f, patches: p)
        try PixelBuf.writeJPEG(out, to: test.appendingPathComponent("eng_\(clip.deletingPathExtension().lastPathComponent)_\(idx).jpg"))
        print("wrote frame", idx, "pts", pts, "patches", p.count); idx += 1
        return !want.isEmpty
    }
}
let sem = DispatchSemaphore(value: 0)
Task { do { try await main() } catch { print("ERROR:", error) }; sem.signal() }
sem.wait()
