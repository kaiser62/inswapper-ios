import CoreVideo
import Foundation
func main() async throws {
    var frames: [CVPixelBuffer] = []
    for p in CommandLine.arguments.dropFirst() {
        let r = try await VideoReader(url: URL(fileURLWithPath: p))
        try r.read(from: 2.0) { f, _ in frames.append(f); return false }
    }
    var se = 0.0, n = 0
    PixelBuf.withBytes(frames[0]) { a, w, h, ba in PixelBuf.withBytes(frames[1]) { b, _, _, bb in
        for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) { for c in 0..<3 { let d = Double(a[y*ba+x*4+c]) - Double(b[y*bb+x*4+c]); se += d*d; n += 1 } } } } }
    PixelBuf.withBytes(frames[0]) { a, w, h, ba in print("sdr  center px BGR:", a[(h/2)*ba+(w/2)*4], a[(h/2)*ba+(w/2)*4+1], a[(h/2)*ba+(w/2)*4+2]) }
    PixelBuf.withBytes(frames[1]) { a, w, h, ba in print("hlg  center px BGR:", a[(h/2)*ba+(w/2)*4], a[(h/2)*ba+(w/2)*4+1], a[(h/2)*ba+(w/2)*4+2]) }
    print(String(format: "sdr10 vs HLG-tagged reader frame PSNR: %.1f dB", 10 * log10(255 * 255 / (se / Double(n)))))
}
var done = false
Task { do { try await main() } catch { print("ERR", error) }; done = true }
while !done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
