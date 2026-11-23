import AVFoundation
let sem = DispatchSemaphore(value: 0)
Task {
    let r = try await VideoReader(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let ar = try AVAssetReader(asset: r.asset)
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: [r.track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.videoComposition = r.composition; ar.add(out); ar.startReading()
    var l: [String] = []
    while let sb = out.copyNextSampleBuffer(), l.count < 6 { l.append("\(Int64(CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1e6)) img=\(CMSampleBufferGetImageBuffer(sb) != nil)") }
    print("composition output first samples:", l)
    print("composition frameDuration us", r.frameDurationUs, "nominal fps track", try await r.track.load(.nominalFrameRate), "minFD", try await r.track.load(.minFrameDuration).seconds)
    sem.signal()
}
sem.wait()
