// Headless player test on the Mac: PlayerEngine + MetalPresenter driven by a 60 Hz timer on the main run loop, offscreen texture.
// Usage: playcheck <models> <clip> <A|B|AB> <seconds> [seekAtHalfTo]
import CoreML
import Foundation
import Metal
import QuartzCore
let root = URL(fileURLWithPath: CommandLine.arguments[1]), compiled = root.appendingPathComponent("compiled")
let clip = URL(fileURLWithPath: CommandLine.arguments[2]), modeArg = CommandLine.arguments[3]
let secs = Double(CommandLine.arguments[4])!
let seekTo = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5])! : nil
var finished = false
Task {
    do {
        let pipe = try FacePipeline(modelsDirectory: compiled)
        let src = try PixelBuf.load(url: root.appendingPathComponent("test/source.jpeg"))
        let lat = try pipe.latent(forSource: src, face: try pipe.detect(src).max { $0.area < $1.area }!)
        let reader = try await VideoReader(url: clip)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("playcheck_cache")
        try? FileManager.default.removeItem(at: cache)
        let eng = PlayerEngine(pipeline: pipe, reader: reader, latent: lat, cacheDirectory: modeArg.contains("A") ? cache : nil, identity: "playcheck")
        eng.mode = modeArg.hasPrefix("A") ? .renderAhead : .livePreview
        eng.combo = modeArg == "AB"
        let pres = MetalPresenter()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: reader.width, height: reader.height, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        let dst = pres.device.makeTexture(descriptor: d)!
        eng.start(); eng.play()
        let t0 = Date(); var frames = 0, withPatch = 0, snaps = 0, nextSnap = 2.0, didSeek = false
        while Date().timeIntervalSince(t0) < secs {
            try await Task.sleep(nanoseconds: 16_000_000)
            let el = Date().timeIntervalSince(t0)
            if let s = seekTo, !didSeek, el > secs / 2 { didSeek = true; eng.seek(to: s); print(String(format: "-- seek to %.1f at %.1fs", s, el)) }
            guard let (f, t) = eng.nextFrame(hostTime: CACurrentMediaTime()) else { continue }
            let ps = eng.patches(at: t)
            if pres.present(frame: f, patches: ps, to: dst) { frames += 1; if !ps.isEmpty { withPatch += 1 } }
            if el > nextSnap, !ps.isEmpty {
                nextSnap += 3; snaps += 1
                try await Task.sleep(nanoseconds: 30_000_000)
                let out = try PixelBuf.make(width: reader.width, height: reader.height)
                PixelBuf.withBytes(out, readOnly: false) { b, w, h, bpr in dst.getBytes(b, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
                try PixelBuf.writeJPEG(out, to: root.appendingPathComponent("test/play_\(modeArg)_\(snaps).jpg"))
            }
        }
        let st = eng.stats
        print(String(format: "mode %@: %d frames presented (%.0f fps), %d with a face patch, skipped %d; playhead %.2fs; swaps %.1f/s; cache %d frames %.1f MB; latency %.0f ms; thermal %d; err %@",
                     modeArg, frames, Double(frames) / secs, withPatch, pres.skipped, eng.currentTime, st.swapsPerSecond, st.cachedFrames, st.cacheMB, st.latencyMs, st.thermal.rawValue, eng.lastError ?? "none"))
        print("rendered ranges:", eng.renderedRanges().map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) })
        eng.shutdown()
    } catch { print("ERROR", error) }
    finished = true
}
while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
