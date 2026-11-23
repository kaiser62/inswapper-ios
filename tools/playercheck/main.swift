// Does AVPlayerItemVideoOutput (with the reader's video composition on the item) return the same geometry and
// timestamps as VideoReader? Usage: playercheck <clip>
import AVFoundation
import Foundation

func main() async throws {
    let r = try await VideoReader(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let item = AVPlayerItem(asset: r.asset)
    item.videoComposition = r.composition
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                              kCVPixelBufferMetalCompatibilityKey as String: true])
    item.add(out)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    for _ in 0..<100 where item.status != .readyToPlay { try await Task.sleep(nanoseconds: 50_000_000) }
    print("item status ready:", item.status == .readyToPlay, "presentationSize:", item.presentationSize, "reader:", r.width, "x", r.height)
    for t in [0.0, 1.0, 2.3, 7.77] {
        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        var got: CVPixelBuffer?; var disp = CMTime.zero
        for _ in 0..<100 {
            var d = CMTime.zero
            if let pb = out.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &d), abs(d.seconds - t) < 0.03 { got = pb; disp = d; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let pb = got else { print("t=\(t): no buffer"); continue }
        let us = Int64((disp.seconds * 1_000_000).rounded())
        var ref: CVPixelBuffer?; var refPts: Int64 = 0
        try r.read(from: t) { f, p in if p >= Int64(t * 1e6) - r.frameDurationUs / 2 { ref = f; refPts = p; return false }; return true }
        var se = 0.0, n = 0
        if let ref {
            PixelBuf.withBytes(pb) { a, w, h, ba in PixelBuf.withBytes(ref) { b, rw, rh, bb in
                if w == rw && h == rh { for y in stride(from: 0, to: h, by: 3) { for x in stride(from: 0, to: w, by: 3) { for c in 0..<3 { let d = Double(a[y * ba + x * 4 + c]) - Double(b[y * bb + x * 4 + c]); se += d * d; n += 1 } } } }
            } }
        }
        let (pw, ph) = PixelBuf.size(pb)
        print(String(format: "t=%.2f  player pts %lld size %dx%d | reader pts %lld | pixel PSNR %.1f dB", t, us, pw, ph, refPts, n == 0 ? 0 : (se == 0 ? 99 : 10 * log10(255 * 255 / (se / Double(n))))))
    }
}
var finished = false
Task { do { try await main() } catch { print("ERROR", error) }; finished = true }
while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
