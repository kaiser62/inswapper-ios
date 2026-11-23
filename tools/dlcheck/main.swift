// usage: dlcheck <path of a local test video>   (downloaded through URLSession via a file:// URL, no server needed)
import Foundation
let arg = CommandLine.arguments[1]
let remote = arg.hasPrefix("https://")
let src = remote ? URL(string: arg)! : URL(fileURLWithPath: arg)
let localCopy = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let sem = DispatchSemaphore(value: 0)
var fails = 0
func check(_ ok: Bool, _ m: String) { print(ok ? "ok:" : "FAIL:", m); if !ok { fails += 1 } }
Task {
    check((try? VideoDownloader.check(URL(string: "https://a.b/x.mp4")!, allowInsecure: false)) != nil, "https mp4 accepted")
    check((try? VideoDownloader.check(URL(string: "http://a.b/x.mp4")!, allowInsecure: false)) == nil, "http rejected by default")
    check((try? VideoDownloader.check(URL(string: "https://a.b/page.html")!, allowInsecure: false)) == nil, "non-video extension rejected")
    check((try? VideoDownloader.check(URL(fileURLWithPath: "/tmp/x.mp4"), allowInsecure: false)) == nil, "file:// rejected by default")
    check(VideoDownloader.safeName(URL(string: "https://cdn.x.com/v/clip.mp4?token=SECRET")!) == "cdn.x.com/clip.mp4", "log name has no query")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vl-\(UUID().uuidString)")
    let lib = VideoLibrary(directory: dir)
    let dl = VideoDownloader()
    var last: Int64 = 0
    do {
        let f = try await dl.download(src, allowInsecure: !remote) { w, _ in last = w }
        check(FileManager.default.fileExists(atPath: f.path), "download produced a temp file (progress bytes \(last))")
        let e = try await lib.add(moving: f, title: "test", source: "localhost")
        if let lc = localCopy, let sz = (try? FileManager.default.attributesOfItem(atPath: lc)[.size]) as? Int64 { check(sz == e.bytes, "downloaded size equals local copy (\(sz))") }
        check(e.duration > 1 && e.width > 0 && e.height > 0 && e.bytes > 1000, "validated: \(e.width)x\(e.height) \(Int(e.duration)) s \(e.bytes) bytes")
        check(FileManager.default.fileExists(atPath: lib.url(of: e).path) && !FileManager.default.fileExists(atPath: f.path), "file moved into library")
        check(FileManager.default.fileExists(atPath: lib.thumbnailURL(of: e).path), "thumbnail written")
        check(VideoLibrary(directory: dir).entries.count == 1, "index persists")
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: 5000).write(to: junk)
        do { _ = try await lib.add(moving: junk, title: "junk", source: "x"); check(false, "junk should be rejected") } catch { check(true, "junk rejected: \(error.localizedDescription)") }
        check(FileManager.default.fileExists(atPath: junk.path), "rejected file left in place")
        try? FileManager.default.removeItem(at: junk)
        lib.delete(id: e.id)
        check(lib.entries.isEmpty && !FileManager.default.fileExists(atPath: lib.url(of: e).path), "delete removes file")
        if remote {
            let bogus = src.deletingLastPathComponent().appendingPathComponent("does-not-exist-123.mp4")
            do { _ = try await dl.download(bogus) { _, _ in }; check(false, "bogus path should fail") } catch { check(true, "non-2xx reported: \(error.localizedDescription)") }
        }
        do { _ = try await dl.download(URL(fileURLWithPath: "/nonexistent/nope.mp4"), allowInsecure: true) { _, _ in }; check(false, "missing file should fail") } catch { check(true, "missing source reported") }
    } catch { check(false, "unexpected: \(error)") }
    try? FileManager.default.removeItem(at: dir)
    print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
    sem.signal()
}
sem.wait()
