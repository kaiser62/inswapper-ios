import AVFoundation
import CoreVideo
import Foundation

enum VideoError: Error { case noVideoTrack, readerFailed(String) }

/// Decodes upright BGRA frames, scaled so the long side is at most `maxLongSide` (720p-class default), starting at any
/// time. AVAssetReader cannot seek: every `read(from:)` creates a fresh reader with a timeRange.
final class VideoReader {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let width: Int, height: Int       // output (upright, scaled) size
    let frameDuration: CMTime
    let duration: Double
    let composition: AVMutableVideoComposition

    init(url: URL, maxLongSide: Int = 1280) async throws {
        asset = AVURLAsset(url: url)
        guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideoTrack }
        track = t
        let natural = try await t.load(.naturalSize), xf = try await t.load(.preferredTransform)
        let minFD = try await t.load(.minFrameDuration)
        let nominal = try await t.load(.nominalFrameRate)
        duration = try await asset.load(.duration).seconds
        let upright = CGRect(origin: .zero, size: natural).applying(xf)
        let s = min(1.0, Double(maxLongSide) / Double(max(upright.width, upright.height)))
        width = Int((upright.width * s / 2).rounded()) * 2; height = Int((upright.height * s / 2).rounded()) * 2
        frameDuration = nominal > 1 ? CMTime(seconds: 1.0 / Double(nominal), preferredTimescale: 1_000_000) : (minFD.isValid && minFD.seconds > 0 ? minFD : CMTime(value: 1, timescale: 30))
        let tf = xf.concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / upright.width, y: CGFloat(height) / upright.height))
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: t)
        li.setTransform(tf, at: .zero)
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        inst.layerInstructions = [li]
        composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = frameDuration
        composition.instructions = [inst]
        // Always deliver SDR Rec.709 frames (HDR / HLG / Dolby Vision phone clips are converted by AVFoundation).
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }

    var frameDurationUs: Int64 { Int64((frameDuration.seconds * 1_000_000).rounded()) }

    /// Calls `handler(frame, ptsMicroseconds)` for each real frame from the one DISPLAYED at `start` (the last frame at or
    /// before it) on, until it returns false or the video ends. PTS values are always the source grid values. AVAssetReader
    /// stamps the first sample of a timeRange with the range start (an off-grid duplicate), so we begin 0.5 s early (also
    /// covers variable-frame-rate gaps) and always drop that first sample.
    func read(from start: Double, handler: (CVPixelBuffer, Int64) throws -> Bool) throws {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        out.videoComposition = composition
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw VideoError.readerFailed("cannot add output") }
        reader.add(out)
        let fd = frameDurationUs, durUs = Int64((duration * 1_000_000).rounded())
        let startUs = min(Int64((max(0, start) * 1_000_000).rounded()), max(0, durUs - fd))   // a start at/after the end still yields the last frame
        let readFrom = max(0, startUs - 500_000)
        reader.timeRange = CMTimeRange(start: CMTime(value: readFrom, timescale: 1_000_000), end: CMTime(seconds: duration, preferredTimescale: 600))
        guard reader.startReading() else { throw VideoError.readerFailed(reader.error?.localizedDescription ?? "startReading") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var first = readFrom > 0       // that sample is the stamped duplicate; at 0 it is a real frame
        var prev: (CVPixelBuffer, Int64)?  // newest frame before `startUs`: the one displayed at `start`
        var go = true
        while go, let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = Int64((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1_000_000).rounded())
            if first { first = false; continue }
            if pts < startUs { prev = (pb, pts); continue }
            if let p = prev { prev = nil; if try !handler(p.0, p.1) { go = false; break } }
            if try !handler(pb, pts) { go = false }
        }
        if go, let p = prev { _ = try handler(p.0, p.1) }
        if reader.status == .failed { throw VideoError.readerFailed(reader.error?.localizedDescription ?? "failed") }
    }
}
