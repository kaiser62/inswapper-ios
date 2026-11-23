// usage: exportcheck <modelsRoot> <clip> <out.mp4> [untilSeconds=4] [strength=100]
// Exports with ExportEngine, then reads the file back: PTS list == source PTS list, audio duration, PSNR of 3 frames vs the Metal compositor.
import AVFoundation
import Foundation
let a = CommandLine.arguments
let root = URL(fileURLWithPath: a[1]), clip = URL(fileURLWithPath: a[2]), out = URL(fileURLWithPath: a[3])
let until = a.count > 4 ? Double(a[4])! : 4, strength = a.count > 5 ? Int(a[5])! : 100
var fails = 0
func check(_ ok: Bool, _ m: String) { print(ok ? "ok:" : "FAIL:", m); if !ok { fails += 1 } }
func rawPts(_ asset: AVURLAsset, until: Int64) async throws -> [Int64] {
    let t = try await asset.loadTracks(withMediaType: .video)[0]
    let r = try AVAssetReader(asset: asset); let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
    r.add(o); r.startReading()
    var l: [Int64] = []
    while let sb = o.copyNextSampleBuffer() { guard CMSampleBufferGetPresentationTimeStamp(sb).isNumeric, CMSampleBufferGetNumSamples(sb) > 0 else { continue }; let p = Int64((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1e6).rounded()); if p < until { l.append(p) } }
    return l.sorted()
}
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let pipe = try FacePipeline(modelsDirectory: root.appendingPathComponent("compiled"))
        let reader = try await VideoReader(url: clip)
        let srcImg = try PixelBuf.load(url: root.appendingPathComponent("test/source.jpeg"))
        guard let sf = try pipe.detect(srcImg).max(by: { $0.area < $1.area }) else { print("no source face"); sem.signal(); return }
        let lat = try pipe.latent(forSource: srcImg, face: sf)
        let store = PatchStore(frameDurationUs: reader.frameDurationUs)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString)")
        store.attach(directory: cache, identity: "exportcheck")
        let eng = ExportEngine(pipeline: pipe, reader: reader, store: store, latent: lat, strength: strength)
        let plan = eng.plan(until: until)
        print("plan: \(plan.width)x\(plan.height) \(plan.frames) frames, disk \(plan.diskNeeded / 1_000_000) MB")
        var last = ""
        let t0 = Date()
        try eng.run(to: out, until: until, cancel: CancelToken(), progress: { p in
            let s = "\(p.phase.rawValue) \(p.done)/\(p.total)"; if s.hasSuffix("0/\(p.total)") || p.phase == .encoding && p.done == p.total { last = s; print(s) }
        })
        print(String(format: "export took %.1f s, file %.1f MB", Date().timeIntervalSince(t0), Double((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1e6))

        // read back: PTS lists
        let outReader = try await VideoReader(url: out)
        var srcPts: [Int64] = [], outPts: [Int64] = []
        let endUs = PatchStore.us(until)
        try reader.read(from: 0) { _, pts in if pts >= endUs { return false }; srcPts.append(pts); return true }
        try outReader.read(from: 0) { _, pts in outPts.append(pts); return true }
        if let i = (0..<min(srcPts.count, outPts.count)).first(where: { abs(srcPts[$0] - outPts[$0]) > 2 }) { print("first mismatch at \(i): src \(srcPts[max(0,i-1)...min(i+2, srcPts.count-1)]) out \(outPts[max(0,i-1)...min(i+2, outPts.count-1)])") }
        let rs = try await rawPts(reader.asset, until: endUs), ro = try await rawPts(outReader.asset, until: endUs)
        print("raw sample PTS: source \(rs.count) \(rs.prefix(4)) | output \(ro.count) \(ro.prefix(4))")
        check(ro.count == srcPts.count && zip(ro, srcPts).allSatisfy { abs($0 - $1) <= 1000 }, "output raw sample PTS == the source frames the reader delivers (+-1 ms, the writer's 1/600 s timebase); max diff \(zip(ro, srcPts).map { abs($0 - $1) }.max() ?? -1) us")
        print("  source raw frames \(rs.count) vs frames the reader delivers \(srcPts.count)")
        let maxDiff = zip(srcPts, outPts).map { abs($0 - $1) }.max() ?? 0
        print("composition-read PTS (informational): ")
        print("info (composition re-grids both files, not a pass/fail):")
        print("  composition-read PTS: \(srcPts.count) vs \(outPts.count) frames, max diff \(maxDiff) us")
        check(outReader.width == reader.width && outReader.height == reader.height, "size \(outReader.width)x\(outReader.height)")
        // audio
        let srcA = try await reader.asset.loadTracks(withMediaType: .audio), outA = try await outReader.asset.loadTracks(withMediaType: .audio)
        if srcA.isEmpty { check(outA.isEmpty, "no audio in source, none in output") }
        else {
            let od = try await outReader.asset.load(.duration).seconds
            check(!outA.isEmpty, "audio track present")
            if let t = outA.first { let r = try await t.load(.timeRange); check(abs(r.duration.seconds - min(until, reader.duration)) < 0.1, String(format: "audio duration %.3f s vs %.3f", r.duration.seconds, min(until, reader.duration))) }
            print(String(format: "file duration %.3f s", od))
        }
        // PSNR: decoded output vs Metal composite of the raw frame + stored patches, at first / middle / last frame
        let pick: Set<Int64> = Set([srcPts.first, srcPts[srcPts.count / 2], srcPts.last].compactMap { $0 })
        let outPick = Set(pick.map { p in outPts.min { abs($0 - p) < abs($1 - p) }! })
        var expect: [Int64: CVPixelBuffer] = [:]
        let comp = MetalCompositor()!
        try reader.read(from: 0) { f, pts in
            if pts >= endUs { return false }
            if pick.contains(pts) { expect[pts] = try comp.composite(f, patches: store.get(displayedAt: pts) ?? []) }
            return true
        }
        do {
            let t = try await outReader.asset.loadTracks(withMediaType: .video)[0]
            let r = try AVAssetReader(asset: outReader.asset)
            let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            r.add(o); r.startReading()
            var seen = Set<Int64>()
            while let sb = o.copyNextSampleBuffer() {
                guard CMSampleBufferGetPresentationTimeStamp(sb).isNumeric, let f = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = Int64((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1e6).rounded())
                guard let key = pick.min(by: { abs($0 - pts) < abs($1 - pts) }), abs(key - pts) <= 1000, !seen.contains(key), let e = expect[key] else { continue }
                seen.insert(key)
                var se = 0.0, n = 0
                PixelBuf.withBytes(e, readOnly: true) { eb, w, h, ebpr in
                    PixelBuf.withBytes(f, readOnly: true) { fb, _, _, fbpr in
                        for y in 0..<h { for x in 0..<w { for c in 0..<3 { let d = Double(eb[y * ebpr + x * 4 + c]) - Double(fb[y * fbpr + x * 4 + c]); se += d * d; n += 1 } } }
                    }
                }
                let psnr = 10 * log10(255 * 255 / max(se / Double(n), 1e-9))
                check(psnr > 33, String(format: "PSNR at %.2f s = %.1f dB", Double(key) / 1e6, psnr))
            }
            check(seen.count == pick.count, "PSNR compared \(seen.count)/\(pick.count) frames")
        }
        try? FileManager.default.removeItem(at: cache)
        // memory cap + resume: cancel at ~30 frames with a small RAM cap, then resume from the same cache directory
        do {
            let cache2 = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString)")
            let s1 = PatchStore(frameDurationUs: reader.frameDurationUs); s1.attach(directory: cache2, identity: "resume")
            let e1 = ExportEngine(pipeline: pipe, reader: reader, store: s1, latent: lat, strength: strength); e1.residentCapBytes = 2_000_000
            let tok = CancelToken(); var maxBytes = 0
            let o1 = FileManager.default.temporaryDirectory.appendingPathComponent("res1-\(UUID().uuidString).mp4")
            do { try e1.run(to: o1, until: until, cancel: tok, progress: { p in maxBytes = max(maxBytes, s1.bytes); if p.phase == .rendering && p.done >= 30 { tok.cancel() } }); check(false, "cancel mid-render should throw") }
            catch ExportEngine.ExportError.cancelled { check(!FileManager.default.fileExists(atPath: o1.path), "mid-render cancel leaves no output file") }
            check(maxBytes <= 2_000_000 + 200_000, "resident patch bytes stayed near the 2 MB cap (peak \(maxBytes))")
            let s2 = PatchStore(frameDurationUs: reader.frameDurationUs); let have = s2.attach(directory: cache2, identity: "resume")
            check(have >= 20 && have < plan.frames, "resume store reloaded \(have) rendered frames from disk")
            let e2 = ExportEngine(pipeline: pipe, reader: reader, store: s2, latent: lat, strength: strength); e2.residentCapBytes = 2_000_000
            var firstDone = -1
            let o2 = FileManager.default.temporaryDirectory.appendingPathComponent("res2-\(UUID().uuidString).mp4")
            try e2.run(to: o2, until: until, cancel: CancelToken(), progress: { p in if firstDone < 0 && p.phase == .rendering { firstDone = p.done } })
            check(firstDone >= 20, "resume starts rendering at \(firstDone) done frames, not 0")
            let ro = try await rawPts(AVURLAsset(url: o2), until: endUs)
            check(ro.count == srcPts.count, "resumed export has all \(ro.count) frames")
            try? FileManager.default.removeItem(at: cache2); try? FileManager.default.removeItem(at: o2)
        }
        // cancel test: a cancelled export leaves no partial file
        let tok = CancelToken(); tok.cancel()
        let o2 = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString).mp4")
        do { try eng.run(to: o2, until: until, cancel: tok, progress: { _ in }); check(false, "cancelled export should throw") }
        catch ExportEngine.ExportError.cancelled { check(!FileManager.default.fileExists(atPath: o2.path), "cancel throws and leaves no output file") }
    } catch { check(false, "unexpected: \(error)") }
    print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
    sem.signal()
}
sem.wait()
