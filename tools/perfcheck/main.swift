// Perf research harness. usage: perfcheck <modelsRoot> <clip> <swapper.mlpackage|baseline> <cpu|cpugpu|cpuane|all> [iters]
// Times the swapper on one real crop under the given compute units, and reports max/mean abs diff (0-255 scale) against the shipped model.
import CoreML
import CoreVideo
import Foundation
let a = CommandLine.arguments
let root = URL(fileURLWithPath: a[1]), clip = URL(fileURLWithPath: a[2]), variant = a[3], units = a[4]
let iters = a.count > 5 ? Int(a[5])! : 30
let cu: MLComputeUnits = ["cpu": .cpuOnly, "cpugpu": .cpuAndGPU, "cpuane": .cpuAndNeuralEngine, "all": .all][units]!
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let pipe = try FacePipeline(modelsDirectory: root.appendingPathComponent("compiled"))
        let reader = try await VideoReader(url: clip)
        var crop: CVPixelBuffer?; var lat: [Float] = []
        try reader.read(from: 2) { frame, _ in
            guard let f = try pipe.detect(frame).max(by: { $0.area < $1.area }) else { return false }
            lat = try pipe.latent(forSource: frame, face: f)
            crop = try PixelBuf.warp(frame, M: FaceAlign.estimate(landmarks: f.landmarks, size: 128), size: 128)
            return false
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = cu
        let url: URL = variant == "baseline" ? root.appendingPathComponent("compiled/swapper.mlmodelc") : try await MLModel.compileModel(at: URL(fileURLWithPath: variant))
        let t0 = Date(); let m = try MLModel(contentsOf: url, configuration: cfg); let loadMs = Date().timeIntervalSince(t0) * 1000
        let l = try MLMultiArray(shape: [1, 512], dataType: .float32); for i in 0..<512 { l[i] = NSNumber(value: lat[i]) }
        func run(_ m: MLModel) throws -> [Float] {
            let o = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["target": MLFeatureValue(pixelBuffer: crop!), "latent": MLFeatureValue(multiArray: l)]))
            return o.featureValue(for: "swapped")!.multiArrayValue!.toFloats()
        }
        let out = try run(m)   // warm-up (ANE compile happens here)
        var ts: [Double] = []
        for _ in 0..<iters { let t = Date(); _ = try run(m); ts.append(Date().timeIntervalSince(t) * 1000) }
        ts.sort()
        let basePipeOut = try run(pipe.swapper)
        var mx: Float = 0, sum: Float = 0
        for i in 0..<out.count { let d = abs(out[i] - basePipeOut[i]) * 255; mx = max(mx, d); sum += d }
        print(String(format: "%@ / %@: load+warm %.0f ms | median %.1f  p10 %.1f  p90 %.1f ms | diff vs shipped: mean %.3f max %.1f (of 255)", (variant as NSString).lastPathComponent, units, loadMs, ts[ts.count/2], ts[ts.count/10], ts[ts.count*9/10], sum / Float(out.count), mx))
    } catch { print("ERR", error) }
    sem.signal()
}
sem.wait()
