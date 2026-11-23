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
        frameDuration = minFD.isValid && minFD.seconds > 0 ? minFD : CMTime(value: 1, timescale: Int32(max(1, nominal.rounded())))
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
    }

    var frameDurationUs: Int64 { Int64((frameDuration.seconds * 1_000_000).rounded()) }

    /// Calls `handler(frame, ptsMicroseconds)` for each real frame from the one covering `start` on, until it returns
    /// false or the video ends. PTS values are always the source grid values: AVAssetReader stamps the first sample of a
    /// timeRange with the range start (an off-grid duplicate), so we begin ~2 frames early and drop that sample.
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
        let fd = frameDurationUs, startUs = Int64((start * 1_000_000).rounded())
        let durUs = Int64((duration * 1_000_000).rounded())
        let readFrom = max(0, min(startUs, durUs - fd) - 2 * fd)   // clamp: a start at/after the end still yields the last frames
        reader.timeRange = CMTimeRange(start: CMTime(value: readFrom, timescale: 1_000_000), end: CMTime(seconds: duration, preferredTimescale: 600))
        guard reader.startReading() else { throw VideoError.readerFailed(reader.error?.localizedDescription ?? "startReading") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var first = true
        var held: (CVPixelBuffer, Int64)?   // first sample, kept until the second shows whether it is the stamped duplicate
        var go = true
        func emit(_ pb: CVPixelBuffer, _ pts: Int64) throws {
            if pts <= min(startUs, durUs - fd) - fd { return }  // before the frame that covers `start`
            if try !handler(pb, pts) { go = false }
        }
        while go, let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = Int64((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1_000_000).rounded())
            if first {
                first = false
                if readFrom == 0 { try emit(pb, pts) } else { held = (pb, pts) }   // at 0 the first sample is a real frame
                continue
            }
            if let h = held {
                held = nil
                if pts - h.1 >= fd * 9 / 10 { try emit(h.0, h.1) }   // not a stamped duplicate (next frame is a full frame away)
                if !go { break }
            }
            try emit(pb, pts)
        }
        if go, let h = held { try emit(h.0, h.1) }
        if reader.status == .failed { throw VideoError.readerFailed(reader.error?.localizedDescription ?? "failed") }
    }
}
