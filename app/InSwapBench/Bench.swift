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


    /// Phase 2 contention test: swapper back-to-back on one thread while SCRFD runs at ~24 Hz on another (what the player
    /// does when a worker swaps while detection also has to keep up). Decides where SCRFD should run.
    static func contention(log: @escaping (String) -> Void) async {
        log("\n== contention: swapper back-to-back + SCRFD at 24 Hz (10 s each)")
        do {
            let swapper = try load("swapper", .cpuAndNeuralEngine)
            let swIn = try input(for: "swapper"), scIn = try input(for: "scrfd")
            // Synchronous Core ML calls must run off the async context (the SDK picks the async overload there).
            func onThread<T>(_ f: @escaping () throws -> T) async throws -> T {
                try await withCheckedThrowingContinuation { c in
                    Thread.detachNewThread { c.resume(with: Result { try f() }) }
                }
            }
            let alone: Int = try await onThread {
                let end = nowMs() + 6000; var n = 0
                while nowMs() < end { _ = try swapper.prediction(from: swIn); n += 1 }
                return n
            }
            log(String(format: "swapper alone: %.2f swaps/s", Double(alone) / 6))
            for (label, units) in [("SCRFD on Neural Engine", MLComputeUnits.cpuAndNeuralEngine), ("SCRFD on CPU", .cpuOnly)] {
                let scrfd = try load("scrfd", units)
                try await onThread { _ = try scrfd.prediction(from: scIn) }   // warm
                var detMs: [Double] = [], swaps = 0
                let lock = NSLock(); let done = DispatchGroup(); let t0 = nowMs(), end = t0 + 10_000
                done.enter()
                Thread.detachNewThread {
                    var n = 0
                    while nowMs() < end { _ = try? swapper.prediction(from: swIn); n += 1 }
                    lock.lock(); swaps = n; lock.unlock(); done.leave()
                }
                done.enter()
                Thread.detachNewThread {
                    var next = nowMs()
                    while nowMs() < end {
                        let a = nowMs(); _ = try? scrfd.prediction(from: scIn); let d = nowMs() - a
                        lock.lock(); detMs.append(d); lock.unlock()
                        next += 1000.0 / 24
                        let wait = next - nowMs()
                        if wait > 0 { Thread.sleep(forTimeInterval: wait / 1000) } else { next = nowMs() }
                    }
                    done.leave()
                }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in done.notify(queue: .global()) { c.resume() } }
                let st = stats(detMs)
                log(String(format: "%@: swaps %.2f/s (alone %.2f), SCRFD %.1f Hz achieved, detect mean %.1f ms p95 %.1f ms, thermal %@",
                           label, Double(swaps) / 10, Double(alone) / 6, Double(detMs.count) / 10, st.mean, st.p95, thermal()))
            }
        } catch { log("contention FAILED: \(error.localizedDescription)") }
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
        await contention(log: log)

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

    /// E2: FP16 swapper vs 8-bit palettized swapper on the ANE: latency, output difference on the same input, 8-bit placement.
    static func swapperCompare(log: @escaping (String) -> Void) async {
        log("\n== swapper compare: FP16 vs 8-bit palettized (cpuAndNeuralEngine, 40 swaps each)")
        guard ModelStore.hasPal8 else { log("swapper_pal8 not installed: import swapper_pal8.zip first"); return }
        do {
            let si = try input(for: "swapper")
            var outs: [[Float]] = []
            for name in ["swapper", "swapper_pal8"] {
                let t0 = nowMs()
                let m = try load(name, .cpuAndNeuralEngine)
                for _ in 0..<3 { _ = try await m.prediction(from: si) }
                log(String(format: "%@: load+warmup %.0f ms", name, nowMs() - t0))
                var ts: [Double] = []
                for _ in 0..<40 { let t = nowMs(); _ = try await m.prediction(from: si); ts.append(nowMs() - t) }
                let st = stats(ts)
                log(String(format: "%@: mean %.1f ms  p95 %.1f ms  thermal %@", name, st.mean, st.p95, thermal()))
                if let o = try await m.prediction(from: si).featureValue(for: "swapped")?.multiArrayValue { outs.append(o.toFloats()) }
                if #available(iOS 17.4, *) { log("\(name) placement: " + ((try? await placement(name)) ?? "?")) }
            }
            if outs.count == 2, outs[0].count == outs[1].count {
                var sum: Float = 0, mx: Float = 0
                for i in 0..<outs[0].count { let d = abs(outs[0][i] - outs[1][i]) * 255; sum += d; mx = max(mx, d) }
                log(String(format: "output difference (synthetic input): mean %.3f max %.1f of 255 (Mac with a real crop: mean 0.6-0.8, max 9)", sum / Float(outs[0].count), mx))
            }
        } catch { log("swapper compare FAILED \(error.localizedDescription)") }
    }

    /// E4: swapper only, back to back, `seconds` long, logging swaps/s and thermal state every 15 s.
    static func sustainedSwapper(_ name: String, seconds: Int, log: @escaping (String) -> Void) async {
        log("\n== sustained \(seconds) s: \(name) back to back, cpuAndNeuralEngine")
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        do {
            let m = try load(name, .cpuAndNeuralEngine), si = try input(for: "swapper")
            for _ in 0..<3 { _ = try await m.prediction(from: si) }
            let start = nowMs(); var n = 0, last = 0; var lastLog = start
            while nowMs() - start < Double(seconds) * 1000 {
                _ = try await m.prediction(from: si); n += 1
                let t = nowMs()
                if t - lastLog >= 15_000 {
                    log(String(format: "t=%3.0fs  %.2f swaps/s  thermal %@", (t - start) / 1000, Double(n - last) / ((t - lastLog) / 1000), thermal()))
                    lastLog = t; last = n
                }
            }
            log(String(format: "average %.2f swaps/s over %d s, final thermal %@", Double(n) / Double(seconds), seconds, thermal()))
        } catch { log("sustained FAILED \(error.localizedDescription)") }
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Would more swap workers raise total swaps/s? N threads swap back to back for `seconds` each, with the same per-swap CPU work as
    /// FacePipeline.swapPass (latent array, output readback, planar RGB -> BGR). "separate" = one MLModel per thread, "shared" = one
    /// MLModel called from all threads. Read the speedup column against N=1 of the same model.
    static func parallelSwapper(seconds: Int = 8, log: @escaping (String) -> Void) async {
        log("\n== parallel swappers: N threads back to back, \(seconds) s per row, cpuAndNeuralEngine")
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        var models = ["swapper"]
        if ModelStore.hasPal8 { models.insert("swapper_pal8", at: 0) }
        do {
            let target = pixelBuffer(128)
            func makeInput() throws -> MLFeatureProvider {
                let latent = try MLMultiArray(shape: [1, 512], dataType: .float32)
                for i in 0..<512 { latent[i] = NSNumber(value: (i % 2 == 0 ? 1 : -1) / Float(512).squareRoot()) }
                return try MLDictionaryFeatureProvider(dictionary: ["target": MLFeatureValue(pixelBuffer: target), "latent": MLFeatureValue(multiArray: latent)])
            }
            /// One swap as the app does it.
            func swapOnce(_ m: MLModel, _ inp: MLFeatureProvider) throws {
                let out = try m.prediction(from: inp)
                guard let p = out.featureValue(for: "swapped")?.multiArrayValue?.toFloats(), p.count == 3 * 128 * 128 else { return }
                var bgr = [UInt8](repeating: 0, count: 128 * 128 * 3)
                let plane = 128 * 128
                for i in 0..<plane { for c in 0..<3 { bgr[i * 3 + c] = UInt8(max(0, min(255, 255 * p[(2 - c) * plane + i]))) } }
                if bgr[0] == 255 && bgr[1] == 254 && bgr[2] == 253 { log("") }   // keeps the loop from being optimised away
            }
            for name in models {
                var base = 0.0
                for (n, shared) in [(1, false), (2, false), (2, true), (3, false), (3, true), (4, false), (4, true)] {
                    let sharedModel = shared ? try load(name, .cpuAndNeuralEngine) : nil
                    let instances = try (0..<n).map { _ in try sharedModel ?? load(name, .cpuAndNeuralEngine) }
                    let inputs = try (0..<n).map { _ in try makeInput() }
                    for k in 0..<n { for _ in 0..<3 { try swapOnce(instances[k], inputs[k]) } }   // warm each instance
                    var counts = [Int](repeating: 0, count: n)
                    let lock = NSLock(), done = DispatchGroup()
                    let end = nowMs() + Double(seconds) * 1000
                    for k in 0..<n {
                        done.enter()
                        Thread.detachNewThread {
                            var c = 0
                            while nowMs() < end { try? swapOnce(instances[k], inputs[k]); c += 1 }
                            lock.lock(); counts[k] = c; lock.unlock(); done.leave()
                        }
                    }
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in done.notify(queue: .global()) { c.resume() } }
                    let total = Double(counts.reduce(0, +)) / Double(seconds)
                    if n == 1 { base = total }
                    log(String(format: "%@ N=%d %@: %.2f swaps/s total (%@) x%.2f vs N=1, thermal %@",
                               name, n, n == 1 ? "single " : (shared ? "shared  " : "separate"), total,
                               counts.map { String(format: "%.1f", Double($0) / Double(seconds)) }.joined(separator: " + "),
                               base > 0 ? total / base : 0, thermal()))
                }
            }
        } catch { log("parallel swappers FAILED \(error.localizedDescription)") }
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        log("DONE")
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
