// Per-stage time table. usage: stagecheck <modelsRoot> <clip> [frames]
import CoreVideo
import Foundation
let a = CommandLine.arguments
let root = URL(fileURLWithPath: a[1]), clip = URL(fileURLWithPath: a[2]), N = a.count > 3 ? Int(a[3])! : 40
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let pipe = try FacePipeline(modelsDirectory: root.appendingPathComponent("compiled"))
        let reader = try await VideoReader(url: clip)
        var lat: [Float] = []
        let src = try PixelBuf.load(url: root.appendingPathComponent("test/source.jpeg"))
        if let f = try pipe.detect(src).max(by: { $0.area < $1.area }) { lat = try pipe.latent(forSource: src, face: f) }
        pipe.resetTimings()
        var n = 0, decodeMs = 0.0, last = Date(), swapTotal = 0.0
        try reader.read(from: 1) { frame, _ in
            decodeMs += Date().timeIntervalSince(last) * 1000
            let t = Date()
            if let f = try pipe.detect(frame).max(by: { $0.area < $1.area }) { _ = try pipe.swap(frame: frame, face: f, latent: lat) }
            swapTotal += Date().timeIntervalSince(t) * 1000
            n += 1; last = Date(); return n < N
        }
        let tm = pipe.timings
        print("frames \(n)  \(reader.width)x\(reader.height)  (per frame, ms)")
        print(String(format: "decode+read   %6.1f", decodeMs / Double(n)))
        for k in tm.keys.sorted() { print(String(format: "%-13@ %6.1f", k as NSString, tm[k]! / Double(n))) }
        print(String(format: "detect+swap total %6.1f", swapTotal / Double(n)))
    } catch { print("ERR", error) }
    sem.signal()
}
sem.wait()
