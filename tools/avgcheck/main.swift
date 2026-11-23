// Does averaging several photos' embeddings give a more stable identity than one photo?
// usage: avgcheck <modelsRoot> <clip>   (frames at fixed times stand in for different photos of one person)
import Foundation
import CoreVideo
let root = URL(fileURLWithPath: CommandLine.arguments[1]), clip = URL(fileURLWithPath: CommandLine.arguments[2])
let sem = DispatchSemaphore(value: 0)
func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
Task {
    do {
        let p = try FacePipeline(modelsDirectory: root.appendingPathComponent("compiled"))
        let r = try await VideoReader(url: clip)
        var embs: [[Float]] = []
        let times = stride(from: 0.5, to: r.duration - 0.5, by: max(0.5, (r.duration - 1) / 8)).prefix(8)
        for t in times {
            try r.read(from: t) { frame, _ in
                if let f = try p.detect(frame).max(by: { $0.area < $1.area }) { embs.append(try p.embedding(forSource: frame, face: f)) }
                return false
            }
        }
        print("embeddings:", embs.count)
        guard embs.count >= 6 else { print("not enough faces"); sem.signal(); return }
        let train = Array(embs.prefix(4)), held = Array(embs.suffix(embs.count - 4))
        let avg = FaceLibrary.averaged(train)!
        func meanCos(_ q: [Float]) -> Float { held.map { cos(q, $0) }.reduce(0, +) / Float(held.count) }
        let singles = train.map { meanCos($0) }
        print(String(format: "held-out mean cosine: single photos %@  avg(4) %.3f", singles.map { String(format: "%.3f", $0) }.joined(separator: " "), meanCos(avg)))
        let latSingle = p.latent(fromEmbedding: train[0]), latAvg = p.latent(fromEmbedding: avg)
        print(String(format: "latent cosine single0 vs avg: %.3f", cos(latSingle, latAvg)))
    } catch { print("ERR", error) }
    sem.signal()
}
sem.wait()
