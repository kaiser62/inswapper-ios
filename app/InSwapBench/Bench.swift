import Foundation
import CoreML
import CoreVideo
import UIKit

enum Bench {
    static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    static func stats(_ a: [Double]) -> (mean: Double, p95: Double) {
        let s = a.sorted()
        let mean = a.reduce(0, +) / Double(max(a.count, 1))
        let p = s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        return (mean, p)
    }

    /// Real BGRA pixel buffer, as the camera/video decoder would hand us.
    static func pixelBuffer(_ side: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let n = CVPixelBufferGetBytesPerRow(buf) * side
        for i in 0..<n { base[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 8)) }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    static func input(for model: String) throws -> MLFeatureProvider {
        switch model {
        case "scrfd":
            return try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer(640))])
        case "arcface":
            return try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: pixelBuffer(112))])
        default:
            let latent = try MLMultiArray(shape: [1, 512], dataType: .float32)
            let p = latent.dataPointer.bindMemory(to: Float.self, capacity: 512)
            for i in 0..<512 { p[i] = (i % 2 == 0 ? 1 : -1) / Float(512).squareRoot() }
            return try MLDictionaryFeatureProvider(dictionary: [
                "target": MLFeatureValue(pixelBuffer: pixelBuffer(128)),
                "latent": MLFeatureValue(multiArray: latent),
            ])
        }
    }

    static func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: ModelStore.compiledURL(name), configuration: cfg)
    }

    static func run(log: @escaping (String) -> Void) async {
        let info: String = await MainActor.run {
            UIApplication.shared.isIdleTimerDisabled = true   // keep screen on: a lock suspends the app mid-run
            return "device \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)"
        }
        log("\(info), thermal \(thermal())")
        log("Keep this app in the foreground. Low Power Mode off, not charging.")

        // Sustained test FIRST, on a cool phone: it is the closest proxy for real playback.
        await sustained(log: log)

        let configs: [(String, MLComputeUnits)] = [
            ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
            ("cpuAndGPU", .cpuAndGPU),
            ("all", .all),
            ("cpuOnly", .cpuOnly),
        ]
        for (label, units) in configs {
            log("\n== \(label)")
            for name in ModelStore.names {
                do {
                    log("loading \(name) (\(label))… first Neural Engine load compiles on device and can take a while")
                    let t0 = nowMs()
                    let model = try load(name, units)
                    let loadMs = nowMs() - t0
                    let inp = try input(for: name)
                    let warm = units == .cpuOnly ? 2 : 10
                    let runs = units == .cpuOnly ? 8 : 60
                    let tw = nowMs()
                    for _ in 0..<warm { _ = try await model.prediction(from: inp) }
                    let warmMs = nowMs() - tw
                    var t: [Double] = []
                    for _ in 0..<runs {
                        let a = nowMs()
                        _ = try await model.prediction(from: inp)
                        t.append(nowMs() - a)
                    }
                    let s = stats(t)
                    log(String(format: "%@: load %.0f ms, warmup %.0f ms, mean %.1f ms, p95 %.1f ms (n=%d)",
                               name, loadMs, warmMs, s.mean, s.p95, runs))
                } catch {
                    log("\(name): FAILED \(error.localizedDescription)")
                }
            }
        }

        if #available(iOS 17.4, *) {
            log("\n== compute plan placement (preferred device per op, cpuAndNeuralEngine)")
            for name in ModelStore.names {
                do { log("\(name): \(try await placement(name))") }
                catch { log("\(name): plan FAILED \(error.localizedDescription)") }
            }
        } else {
            log("\n(compute plan skipped: needs iOS 17.4+)")
        }

        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        log("\nDONE")
    }

    /// 60 s loop of scrfd + swapper per frame on cpuAndNeuralEngine.
    /// Pessimistic (detects every frame) and optimistic (no letterbox/align/paste-back): read as a rough proxy.
    static func sustained(log: @escaping (String) -> Void) async {
        log("\n== sustained 60 s: scrfd + swapper per frame, cpuAndNeuralEngine")
        do {
            log("loading scrfd + swapper… (first load compiles on device, can take a while)")
            let t0 = nowMs()
            let det = try load("scrfd", .cpuAndNeuralEngine)
            let swp = try load("swapper", .cpuAndNeuralEngine)
            let di = try input(for: "scrfd"), si = try input(for: "swapper")
            for _ in 0..<5 { _ = try await det.prediction(from: di); _ = try await swp.prediction(from: si) }
            log(String(format: "load + warmup %.0f ms (includes one-time compile on first run)", nowMs() - t0))
            let start = nowMs()
            var frames = 0, lastFrames = 0
            var lastLog = start
            while nowMs() - start < 60_000 {
                _ = try await det.prediction(from: di)
                _ = try await swp.prediction(from: si)
                frames += 1
                let t = nowMs()
                if t - lastLog >= 5_000 {
                    let fps = Double(frames - lastFrames) / ((t - lastLog) / 1000)
                    log(String(format: "t=%2.0fs fps %.1f thermal %@", (t - start) / 1000, fps, thermal()))
                    lastLog = t; lastFrames = frames
                }
            }
            log(String(format: "sustained avg %.1f fps over 60 s, final thermal %@",
                       Double(frames) / 60.0, thermal()))
        } catch {
            log("sustained FAILED \(error.localizedDescription)")
        }
    }

    @available(iOS 17.4, *)
    static func placement(_ name: String) async throws -> String {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: ModelStore.compiledURL(name), configuration: cfg)
        guard case let .program(program) = plan.modelStructure, let main = program.functions["main"] else {
            return "not an ML program"
        }
        var counts: [String: Int] = [:]
        for op in main.block.operations where op.operatorName != "const" {
            var dev = "none"
            if let usage = plan.deviceUsage(for: op) {
                switch usage.preferred {
                case .cpu: dev = "CPU"
                case .gpu: dev = "GPU"
                case .neuralEngine: dev = "ANE"
                @unknown default: dev = "?"
                }
            }
            counts[dev, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}
