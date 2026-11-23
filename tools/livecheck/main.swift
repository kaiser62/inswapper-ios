// args: <models> <clip> <start> <seconds> [jump=4] [rate=1]  (rate 0 = frozen playhead; jump applied at half time)
// Mode B headless check: simulated playhead (wall clock from <start>), reports update rate and how far the patch's
// frame time is from the playhead when it lands (ideal ~0). Usage: livecheck <models> <clip> <start> <seconds> [seekToAt:seekTo]
import CoreML
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1]), compiled = root.appendingPathComponent("compiled")
let clip = URL(fileURLWithPath: CommandLine.arguments[2])
let jump = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5])! : 4
let rate = CommandLine.arguments.count > 6 ? Double(CommandLine.arguments[6])! : 1
let start = Double(CommandLine.arguments[3])!, secs = Double(CommandLine.arguments[4])!
func main() async throws {
    let pipe = try FacePipeline(modelsDirectory: compiled)
    let src = try PixelBuf.load(url: root.appendingPathComponent("test/source.jpeg"))
    let lat = try pipe.latent(forSource: src, face: try pipe.detect(src).max { $0.area < $1.area }!)
    let reader = try await VideoReader(url: clip)
    let store = PatchStore(frameDurationUs: reader.frameDurationUs)
    let w = LiveWorker(pipeline: pipe, reader: reader, store: store, latent: lat)
    let t0 = Date(); var offset = start; let lock = NSLock()
    let playhead: () -> Double = { lock.lock(); defer { lock.unlock() }; return offset + rate * Date().timeIntervalSince(t0) }
    let cancel = CancelToken()
    var lags: [Double] = []; var landed: [Double] = []; var jumpAt: Date?; var recovered: Double?
    DispatchQueue.global().async {   // simulated seek: jump forward 4 s at half time
        Thread.sleep(forTimeInterval: secs / 2); lock.lock(); offset += jump; jumpAt = Date(); lock.unlock(); print("-- seek +\(jump) s")
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + secs) { cancel.cancel() }
    try w.run(playhead: playhead, cancel: cancel) { pts in
        let ph = playhead(); lags.append(Double(pts) / 1e6 - ph); landed.append(ph)
        if let j = jumpAt, recovered == nil, abs(Double(pts) / 1e6 - ph) < 0.15, Double(pts) / 1e6 > start + jump - 1 { recovered = Date().timeIntervalSince(j) }
    }
    let ok = lags.dropFirst(2).filter { $0 > -1 }
    print(String(format: "%d swaps in %.0fs = %.2f/s; patch frame time minus playhead at arrival: mean %+.0f ms, min %+.0f, max %+.0f; final latency estimate %.0f ms",
                 w.swaps, secs, Double(w.swaps) / secs, ok.reduce(0, +) / Double(max(1, ok.count)) * 1000, (ok.min() ?? 0) * 1000, (ok.max() ?? 0) * 1000, w.latency * 1000))
    print("time from jump to first on-time patch:", recovered.map { String(format: "%.2f s", $0) } ?? "never")
    print("store frames kept:", store.count, "bytes:", store.bytes)
}
var done = false
Task { do { try await main() } catch { print("ERROR", error) }; done = true }
while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
