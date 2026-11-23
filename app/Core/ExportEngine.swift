import AVFoundation
import CoreVideo
import Foundation

/// Offline export (R5): phase 1 fills the persistent patch store with a swap for every source frame (resumes for free: frames
/// already on disk are skipped); phase 2 re-reads the video, pastes the stored patches with the Metal compositor and encodes
/// HEVC with the source audio. Output size = decode size (VideoReader caps the long side at 1280).
/// Run `run` on a background thread with the Player engine shut down (two writers must never share a store).
final class ExportEngine {
    enum Phase: String { case rendering, encoding }
    struct Progress { var phase: Phase; var done: Int; var total: Int }
    enum ExportError: Error, LocalizedError {
        case cancelled, writer(String), noSpace(need: Int64, free: Int64), compositor
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Export cancelled."
            case .writer(let m): return "Could not write the video: \(m)"
            case .noSpace(let n, let f): return String(format: "Not enough free space: need about %.0f MB, have %.0f MB.", Double(n) / 1e6, Double(f) / 1e6)
            case .compositor: return "The GPU compositor is not available."
            }
        }
    }

    /// What an export will cost, for the confirmation sheet.
    struct Plan {
        var width: Int, height: Int, frames: Int, alreadyRendered: Int
        var remainingFrames: Int { max(0, frames - alreadyRendered) }
        /// Patch cache growth (about 49 KB per frame) + output file (bitrate x duration) + 200 MB headroom.
        var diskNeeded: Int64
        func seconds(swapsPerSecond: Double) -> Double { Double(remainingFrames) / max(0.5, swapsPerSecond) + Double(frames) / 120 }
    }

    let pipeline: FacePipeline, reader: VideoReader, store: PatchStore, latent: [Float], strength: Int
    private let presenter: MetalCompositor?

    init(pipeline: FacePipeline, reader: VideoReader, store: PatchStore, latent: [Float], strength: Int = 100) {
        self.pipeline = pipeline; self.reader = reader; self.store = store; self.latent = latent; self.strength = strength
        presenter = MetalCompositor()
    }

    static func bitrate(width: Int, height: Int, fps: Double) -> Int { max(3_000_000, Int(Double(width * height) * fps * 0.12)) }   // HEVC, ~0.12 bit/pixel
    static func estimatedFrames(reader: VideoReader, until: Double? = nil) -> Int {
        Int(((until.map { min($0, reader.duration) } ?? reader.duration) / max(0.001, reader.frameDuration.seconds)).rounded())
    }

    func plan(until: Double? = nil) -> Plan {
        let frames = Self.estimatedFrames(reader: reader, until: until)
        let fps = 1 / max(0.001, reader.frameDuration.seconds)
        let secs = until.map { min($0, reader.duration) } ?? reader.duration
        let done = min(frames, store.count)
        let out = Int64(Double(Self.bitrate(width: reader.width, height: reader.height, fps: fps)) * secs / 8)
        return Plan(width: reader.width, height: reader.height, frames: frames, alreadyRendered: done,
                    diskNeeded: Int64(frames - done) * 50_000 + out + 200_000_000)
    }

    /// Blocks until done. `gate` is called before every frame in both phases (pause / thermal hook; must return when cancelled).
    /// Throws `.cancelled` after cancel; the partial file is deleted and the patch cache is kept (render progress survives).
    func run(to output: URL, until: Double? = nil, cancel: CancelToken, gate: (() -> Void)? = nil, progress: @escaping (Progress) -> Void) throws {
        let fm = FileManager.default
        let p = plan(until: until)
        let free = VideoDownloader.freeBytes(at: output.deletingLastPathComponent())
        if free < p.diskNeeded { throw ExportError.noSpace(need: p.diskNeeded, free: free) }

        // phase 1: render every missing frame
        let total = p.frames
        var sinceFlush = 0
        progress(Progress(phase: .rendering, done: min(total, store.count), total: total))
        let worker = RenderWorker(pipeline: pipeline, reader: reader, store: store, latent: latent, strength: strength)
        try worker.run(from: 0, until: until, cancel: cancel, gate: gate, onFrame: { [store] _ in
            sinceFlush += 1
            if sinceFlush >= Int(PatchStore.chunkFrames) { sinceFlush = 0; store.flush() }
            progress(Progress(phase: .rendering, done: min(total, store.count), total: total))
        })
        store.flush()
        if cancel.isCancelled { throw ExportError.cancelled }

        // phase 2: composite + encode (cheap; a failure here simply reruns this phase)
        let tmp = output.deletingLastPathComponent().appendingPathComponent(".partial-" + output.lastPathComponent)
        try? fm.removeItem(at: tmp)
        do {
            try encode(to: tmp, until: until, cancel: cancel, gate: gate, total: total, progress: progress)
        } catch {
            try? fm.removeItem(at: tmp); throw error
        }
        try? fm.removeItem(at: output)
        try fm.moveItem(at: tmp, to: output)
    }

    private func encode(to url: URL, until: Double?, cancel: CancelToken, gate: (() -> Void)?, total: Int, progress: (Progress) -> Void) throws {
        let w = reader.width, h = reader.height
        let fps = 1 / max(0.001, reader.frameDuration.seconds)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Self.bitrate(width: w, height: h, fps: fps)]])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(vIn) else { throw ExportError.writer("cannot add video input") }
        writer.add(vIn)

        // audio: AAC is passed through untouched, anything else is decoded and re-encoded to AAC; no audio track is fine
        var aOut: AVAssetReaderTrackOutput?, aIn: AVAssetWriterInput?, aReader: AVAssetReader?
        if let at = reader.asset.tracks(withMediaType: .audio).first {
            let fd = at.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let asbd = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let isAAC = asbd?.mFormatID == kAudioFormatMPEG4AAC
            let ar = try AVAssetReader(asset: reader.asset)
            if let u = until { ar.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: u, preferredTimescale: 600)) }
            let out = AVAssetReaderTrackOutput(track: at, outputSettings: isAAC ? nil : [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: isAAC ? nil : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: Int(asbd?.mChannelsPerFrame ?? 2),
                AVSampleRateKey: asbd?.mSampleRate ?? 44100, AVEncoderBitRateKey: 128_000 * max(1, Int(asbd?.mChannelsPerFrame ?? 2) / 2)],
                sourceFormatHint: isAAC ? fd : nil)
            inp.expectsMediaDataInRealTime = false
            if ar.canAdd(out), writer.canAdd(inp) { ar.add(out); writer.add(inp); aOut = out; aIn = inp; aReader = ar }
        }
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let audioDone = DispatchSemaphore(value: 0)
        let audioQueue = DispatchQueue(label: "export.audio")
        let flag = FinishFlag()
        if let ar = aReader, let out = aOut, let inp = aIn {
            guard ar.startReading() else { throw ExportError.writer(ar.error?.localizedDescription ?? "audio startReading") }
            inp.requestMediaDataWhenReady(on: audioQueue) {
                while inp.isReadyForMoreMediaData && !flag.isSet {
                    if !cancel.isCancelled, let sb = out.copyNextSampleBuffer(), inp.append(sb) { continue }
                    if flag.setOnce() { inp.markAsFinished(); audioDone.signal() }
                }
            }
        }

        let endUs = until.map { PatchStore.us($0) }
        var n = 0
        var failure: Error?
        do {
            try reader.read(from: 0) { frame, pts in
                gate?()
                if cancel.isCancelled { return false }
                if let e = endUs, pts >= e { return false }
                // completeness: a frame missing from the store is rendered now, never written raw
                var patches = store.get(displayedAt: pts)
                if patches == nil {
                    let face = try pipeline.detect(frame).max { $0.area < $1.area }
                    let made = try face.map { [try pipeline.swap(frame: frame, face: $0, latent: latent, strength: strength)] } ?? []
                    store.put(pts: pts, made); patches = made
                }
                guard let comp = presenter else { throw ExportError.compositor }
                let outBuf = try comp.composite(frame, patches: patches ?? [])
                while !vIn.isReadyForMoreMediaData {
                    if cancel.isCancelled || writer.status == .failed { return false }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if !adaptor.append(outBuf, withPresentationTime: CMTime(value: pts, timescale: 1_000_000)) {
                    failure = ExportError.writer(writer.error?.localizedDescription ?? "append failed"); return false
                }
                n += 1
                if n % 8 == 0 { progress(Progress(phase: .encoding, done: n, total: total)) }
                return true
            }
        } catch { failure = error }

        vIn.markAsFinished()
        if aIn != nil { if cancel.isCancelled || failure != nil { if flag.setOnce() { audioDone.signal() } }; audioDone.wait() }
        if cancel.isCancelled { writer.cancelWriting(); throw ExportError.cancelled }
        if let f = failure { writer.cancelWriting(); throw f }
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw ExportError.writer(writer.error?.localizedDescription ?? "finishWriting") }
        progress(Progress(phase: .encoding, done: n, total: total))
    }
}

/// Set-once flag shared by the audio queue and the export thread.
private final class FinishFlag {
    private let lock = NSLock(); private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    /// true for the first caller only
    func setOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if v { return false }; v = true; return true }
}
