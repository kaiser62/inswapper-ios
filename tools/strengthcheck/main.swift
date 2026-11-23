// Strength regression/measure. usage: strengthcheck <modelsRoot> <clip> [strength]
// Without -DNEWAPI: prints a hash per frame using the legacy swap(frame:face:latent:) (baseline).
// With -DNEWAPI: uses swap(..., strength:) and also prints ArcFace cosine to the source and time.
import CoreVideo
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1]), clip = URL(fileURLWithPath: CommandLine.arguments[2])
let strength = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 100
func fnv(_ b: [UInt8]) -> String { var h: UInt64 = 1469598103934665603; for x in b { h = (h ^ UInt64(x)) &* 1099511628211 }; return String(h, radix: 16) }
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let pipe = try FacePipeline(modelsDirectory: root.appendingPathComponent("compiled"))
        let src = try PixelBuf.load(url: root.appendingPathComponent("test/source.jpeg"))
        let sf = try pipe.detect(src).max { $0.area < $1.area }!
        let lat = try pipe.latent(forSource: src, face: sf)
        let srcEmb = try pipe.embedding(forSource: src, face: sf)
        let reader = try await VideoReader(url: clip)
        var n = 0
        for t in [1.0, 4.0, 8.0] {
            try reader.read(from: t) { frame, _ in
                guard let f = try pipe.detect(frame).max(by: { $0.area < $1.area }) else { return false }
                let t0 = Date()
                #if NEWAPI
                let p = try pipe.swap(frame: frame, face: f, latent: lat, strength: strength)
                #else
                let p = try pipe.swap(frame: frame, face: f, latent: lat)
                #endif
                let ms = Date().timeIntervalSince(t0) * 1000
                // identity score: re-detect the composited frame, cosine to the source embedding
                let out = try Compositor.composite(frame, patches: [p])
                var cs = "-"
                if let f2 = try pipe.detect(out).max(by: { $0.area < $1.area }) {
                    let e = try pipe.embedding(forSource: out, face: f2)
                    cs = String(format: "%.3f", zip(e, srcEmb).reduce(0) { $0 + $1.0 * $1.1 })
                }
                print("t=\(t) hash \(fnv(p.bgr)) cosToSource \(cs) swap \(Int(ms)) ms")
                n += 1; return false
            }
        }
    } catch { print("ERR", error) }
    sem.signal()
}
sem.wait()
