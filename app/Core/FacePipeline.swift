import CoreML
import CoreVideo
import Foundation

struct DetectedFace {
    var x1: Double, y1: Double, x2: Double, y2: Double
    var score: Float
    var landmarks: [Point]  // 5 points: left eye, right eye, nose, left mouth, right mouth
    var area: Double { (x2 - x1) * (y2 - y1) }
}

/// A swapped face in canonical coordinates: 128x128 BGR bytes + the transform image -> aligned patch.
/// This (not a full swapped frame) is what gets cached per frame (see specs/03).
struct SwapPatch {
    var bgr: [UInt8]  // 128*128*3
    var M: Affine
}

enum PipelineError: Error { case noFace, badModel(String) }

/// Loads the three Core ML models (.mlmodelc) and emap. Sync, frame-in / patch-out.
final class FacePipeline {
    let scrfd: MLModel, scrfdCPU: MLModel, arcface: MLModel, swapper: MLModel
    /// Detect on the CPU (24 ms, leaves the ANE to the swapper) when another worker is swapping at the same time; ANE (4 ms) otherwise.
    private let cpuLock = NSLock(); private var _cpuDetector = false
    var cpuDetector: Bool { get { cpuLock.lock(); defer { cpuLock.unlock() }; return _cpuDetector } set { cpuLock.lock(); _cpuDetector = newValue; cpuLock.unlock() } }
    let emap: [Float]  // 512x512 row-major
    private let latentShape: [NSNumber]
    /// Accumulated per-stage wall time in ms (reset with `resetTimings`). Shown in the app to measure the Swift CPU cost.
    private let timingLock = NSLock()
    private var _timings: [String: Double] = [:]
    var timings: [String: Double] { timingLock.lock(); defer { timingLock.unlock() }; return _timings }
    func resetTimings() { timingLock.lock(); _timings = [:]; timingLock.unlock() }
    func addTiming(_ k: String, _ ms: Double) { timingLock.lock(); _timings[k, default: 0] += ms; timingLock.unlock() }
    private func timed<T>(_ k: String, _ f: () throws -> T) rethrows -> T {
        let t = Date(); defer { addTiming(k, Date().timeIntervalSince(t) * 1000) }
        return try f()
    }

    init(modelsDirectory dir: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let cfg = MLModelConfiguration(); cfg.computeUnits = computeUnits
        func load(_ n: String) throws -> MLModel { try MLModel(contentsOf: dir.appendingPathComponent(n + ".mlmodelc"), configuration: cfg) }
        scrfd = try load("scrfd")
        let cc = MLModelConfiguration(); cc.computeUnits = .cpuOnly
        scrfdCPU = try MLModel(contentsOf: dir.appendingPathComponent("scrfd.mlmodelc"), configuration: cc)
        arcface = try load("arcface"); swapper = try load("swapper")
        let data = try Data(contentsOf: dir.appendingPathComponent("emap.bin"))
        guard data.count == 512 * 512 * 4 else { throw PipelineError.badModel("emap.bin size") }
        emap = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        latentShape = swapper.modelDescription.inputDescriptionsByName["latent"]?.multiArrayConstraint?.shape ?? [1, 512]
    }

    // MARK: detection (SCRFD buffalo_l det_10g, fixed 640x640)
    func detect(_ frame: CVPixelBuffer, threshold: Float = 0.5) throws -> [DetectedFace] {
        let (canvas, scale) = try timed("letterbox") { try PixelBuf.letterbox(frame) }
        let out = try timed("scrfd") { try (cpuDetector ? scrfdCPU : scrfd).prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: canvas)])) }
        let tDecode = Date(); defer { addTiming("decode+nms", Date().timeIntervalSince(tDecode) * 1000) }
        func arr(_ n: String) throws -> [Float] {
            guard let a = out.featureValue(for: n)?.multiArrayValue else { throw PipelineError.badModel("missing output " + n) }
            return timed("readback") { a.toFloats() }
        }
        var cand: [DetectedFace] = []
        for (idx, stride) in [8, 16, 32].enumerated() {
            let scores = try arr("score_\(stride)"), bbox = try arr("bbox_\(stride)"), kps = try arr("kps_\(stride)")
            let cells = 640 / stride
            let st = Float(stride)
            for i in 0..<scores.count where scores[i] >= threshold {
                let cell = i / 2  // two anchors per cell, centres repeated consecutively
                let cx = Float(cell % cells) * st, cy = Float(cell / cells) * st
                let inv = 1 / scale
                let b0 = Double(cx - bbox[i * 4] * st) * inv, b1 = Double(cy - bbox[i * 4 + 1] * st) * inv
                let b2 = Double(cx + bbox[i * 4 + 2] * st) * inv, b3 = Double(cy + bbox[i * 4 + 3] * st) * inv
                var lm: [Point] = []
                for k in 0..<5 {
                    lm.append((Double(cx + kps[i * 10 + 2 * k] * st) * inv, Double(cy + kps[i * 10 + 2 * k + 1] * st) * inv))
                }
                cand.append(DetectedFace(x1: b0, y1: b1, x2: b2, y2: b3, score: scores[i], landmarks: lm))
            }
            _ = idx
        }
        return Self.nms(cand.sorted { $0.score > $1.score }, iou: 0.4)
    }

    static func nms(_ sorted: [DetectedFace], iou thr: Double) -> [DetectedFace] {
        var keep: [DetectedFace] = []
        var rest = sorted
        while let f = rest.first {
            keep.append(f)
            rest = rest.dropFirst().filter { o in
                let xx1 = max(f.x1, o.x1), yy1 = max(f.y1, o.y1), xx2 = min(f.x2, o.x2), yy2 = min(f.y2, o.y2)
                let inter = max(0, xx2 - xx1 + 1) * max(0, yy2 - yy1 + 1)
                let a1 = (f.x2 - f.x1 + 1) * (f.y2 - f.y1 + 1), a2 = (o.x2 - o.x1 + 1) * (o.y2 - o.y1 + 1)
                return inter / (a1 + a2 - inter) <= thr
            }
        }
        return keep
    }

    // MARK: source identity
    /// L2-normalised ArcFace embedding (512) of one source face. Kept separate so several photos can be averaged.
    func embedding(forSource frame: CVPixelBuffer, face: DetectedFace) throws -> [Float] {
        let M = FaceAlign.estimate(landmarks: face.landmarks, size: 112)
        let crop = try timed("warp") { try PixelBuf.warp(frame, M: M, size: 112) }
        let out = try timed("arcface") { try arcface.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: crop)])) }
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue?.toFloats(), e.count == 512
        else { throw PipelineError.badModel("embedding") }
        return FaceLibrary.normalised(e)
    }

    /// latent = L2norm( emb @ emap ) for an already L2-normalised (possibly averaged) embedding.
    func latent(fromEmbedding e: [Float]) -> [Float] {
        var lat = [Float](repeating: 0, count: 512)
        for i in 0..<512 { let v = e[i]; for j in 0..<512 { lat[j] += v * emap[i * 512 + j] } }
        return FaceLibrary.normalised(lat)
    }

    /// latent = L2norm( L2norm(arcface(aligned112)) @ emap ), computed once per source face.
    func latent(forSource frame: CVPixelBuffer, face: DetectedFace) throws -> [Float] {
        latent(fromEmbedding: try embedding(forSource: frame, face: face))
    }

    // MARK: swap
    func swap(frame: CVPixelBuffer, face: DetectedFace, latent: [Float]) throws -> SwapPatch {
        let M = FaceAlign.estimate(landmarks: face.landmarks, size: 128)
        let crop = try timed("warp") { try PixelBuf.warp(frame, M: M, size: 128) }
        let lat = try MLMultiArray(shape: latentShape, dataType: .float32)
        for i in 0..<512 { lat[i] = NSNumber(value: latent[i]) }
        let out = try timed("swapper") { try swapper.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "target": MLFeatureValue(pixelBuffer: crop), "latent": MLFeatureValue(multiArray: lat)])) }
        guard let p = timed("readback", { out.featureValue(for: "swapped")?.multiArrayValue?.toFloats() }), p.count == 3 * 128 * 128
        else { throw PipelineError.badModel("swapped") }
        var bgr = [UInt8](repeating: 0, count: 128 * 128 * 3)
        let plane = 128 * 128
        for i in 0..<plane {  // planar RGB 0..1 -> interleaved BGR bytes (truncating, like astype(uint8))
            for c in 0..<3 {
                bgr[i * 3 + c] = UInt8(max(0, min(255, 255 * p[(2 - c) * plane + i])))
            }
        }
        return SwapPatch(bgr: bgr, M: M)
    }
}
