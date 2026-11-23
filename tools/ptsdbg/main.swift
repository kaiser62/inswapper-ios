// usage: ptsdbg <clip> [sync]  -- compares frames the VideoReader delivers against raw-decoded source frames
import AVFoundation
let sem = DispatchSemaphore(value: 0)
func copy(_ pb: CVPixelBuffer) -> [UInt8] {
    var out: [UInt8] = []
    PixelBuf.withBytes(pb, readOnly: true) { b, w, h, bpr in for y in 0..<h { out.append(contentsOf: UnsafeBufferPointer(start: b + y * bpr, count: w * 4)) } }
    return out
}
func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double { guard a.count == b.count else { return -1 }; var s = 0.0; for i in 0..<a.count { let d = Double(a[i]) - Double(b[i]); s += d * d }; return 10 * log10(255 * 255 / max(s / Double(a.count), 1e-9)) }
Task {
    let r = try await VideoReader(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    if CommandLine.arguments.count > 2 { r.composition.sourceTrackIDForFrameTiming = r.track.trackID; print("sourceTrackIDForFrameTiming set") }
    var raw: [(Int64, [UInt8])] = []
    let ar = try AVAssetReader(asset: r.asset)
    let o = AVAssetReaderTrackOutput(track: r.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    ar.add(o); ar.startReading()
    while let sb = o.copyNextSampleBuffer(), raw.count < 8 { guard let f = CMSampleBufferGetImageBuffer(sb), CMSampleBufferGetPresentationTimeStamp(sb).isNumeric else { continue }; raw.append((Int64((CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1e6).rounded()), copy(f))) }
    raw.sort { $0.0 < $1.0 }
    var got: [(Int64, [UInt8])] = []
    try r.read(from: 0) { f, pts in got.append((pts, copy(f))); return got.count < 6 }
    print("raw pts:", raw.map { $0.0 })
    print("reader pts:", got.map { $0.0 })
    for g in got { print("reader frame \(g.0): PSNR vs raw", raw.map { String(format: "%d:%.1f", $0.0, psnr(g.1, $0.1)) }.joined(separator: "  ")) }
    sem.signal()
}
sem.wait()
