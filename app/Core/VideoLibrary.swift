import AVFoundation
import Foundation
import ImageIO

/// Local video library: files copied/downloaded into `directory` under random names, with a JSON index and thumbnails.
/// Everything stays on the device; log lines use host + file name only.
final class VideoLibrary {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String, title: String, file: String, bytes: Int64, duration: Double, width: Int, height: Int, created: Date, source: String
    }
    enum LibError: Error, LocalizedError {
        case notPlayable, noVideoTrack
        var errorDescription: String? { self == .notPlayable ? "That file is not a playable video." : "That file has no video track." }
    }

    let directory: URL
    private(set) var entries: [Entry] = []
    private let lock = NSLock()
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL), let e = try? JSONDecoder.lib.decode([Entry].self, from: d) { entries = e }
    }
    private func save() { if let d = try? JSONEncoder.lib.encode(entries) { try? d.write(to: indexURL, options: .atomic) } }

    func url(of e: Entry) -> URL { directory.appendingPathComponent(e.file) }
    func thumbnailURL(of e: Entry) -> URL { directory.appendingPathComponent(e.id + ".jpg") }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    /// Checks the file is a playable video; returns (duration s, width, height) of the upright video.
    static func validate(_ url: URL) async throws -> (Double, Int, Int) {
        let a = AVURLAsset(url: url)
        guard try await a.load(.isPlayable) else { throw LibError.notPlayable }
        guard let t = try await a.loadTracks(withMediaType: .video).first else { throw LibError.noVideoTrack }
        let n = try await t.load(.naturalSize), xf = try await t.load(.preferredTransform)
        let r = CGRect(origin: .zero, size: n).applying(xf)
        return (try await a.load(.duration).seconds, Int(abs(r.width).rounded()), Int(abs(r.height).rounded()))
    }

    /// Moves `file` into the library (validates first; on failure the file is left where it was). `source` = host or "Photos"/"Files".
    @discardableResult
    func add(moving file: URL, title: String, source: String) async throws -> Entry {
        let (dur, w, h) = try await Self.validate(file)
        let id = UUID().uuidString
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension.lowercased()
        let name = id + "." + ext
        let dst = directory.appendingPathComponent(name)
        do { try FileManager.default.moveItem(at: file, to: dst) } catch { try FileManager.default.copyItem(at: file, to: dst) }
        let bytes = Int64((try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let e = Entry(id: id, title: title, file: name, bytes: bytes, duration: dur, width: w, height: h, created: Date(), source: source)
        await makeThumbnail(for: dst, to: directory.appendingPathComponent(id + ".jpg"), duration: dur)
        append(e)
        return e
    }

    private func append(_ e: Entry) { lock.lock(); entries.insert(e, at: 0); save(); lock.unlock() }

    func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(of: e)); try? FileManager.default.removeItem(at: thumbnailURL(of: e))
        entries.removeAll { $0.id == id }; save()
    }

    private func makeThumbnail(for video: URL, to out: URL, duration: Double) async {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 320, height: 320)
        guard let r = try? await g.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)) else { return }
        let rep = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(rep, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, r.image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            if CGImageDestinationFinalize(dest) { try? (rep as Data).write(to: out) }
        }
    }
}

private extension JSONEncoder { static var lib: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
private extension JSONDecoder { static var lib: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

/// Foreground download of a direct video file link (HTTPS only unless `allowInsecure`, which tests use for file:// / localhost).
/// Checks free disk space against Content-Length as soon as it is known; keeps resume data after a failure.
final class VideoDownloader: NSObject, URLSessionDownloadDelegate {
    enum DLError: Error, LocalizedError {
        case badURL, notHTTPS, http(Int), notEnoughSpace(need: Int64, free: Int64), cancelled
        var errorDescription: String? {
            switch self {
            case .badURL: return "That does not look like a link to a video file."
            case .notHTTPS: return "Only https:// links are supported."
            case .http(let c): return "The server answered with error \(c)."
            case .notEnoughSpace(let n, let f): return String(format: "Not enough free space: need %.0f MB, have %.0f MB.", Double(n) / 1e6, Double(f) / 1e6)
            case .cancelled: return "Download cancelled."
            }
        }
    }
    static let allowedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Host + file name only: never the query string, and nothing else of the URL.
    static func safeName(_ u: URL) -> String { (u.host ?? "local") + "/" + u.lastPathComponent }

    static func check(_ u: URL, allowInsecure: Bool) throws {
        guard let scheme = u.scheme?.lowercased(), allowedExtensions.contains(u.pathExtension.lowercased()) else { throw DLError.badURL }
        if scheme == "https", u.host != nil { return }
        if allowInsecure, scheme == "file" || scheme == "http" { return }
        throw scheme == "http" ? DLError.notHTTPS : DLError.badURL
    }

    static func freeBytes(at dir: URL) -> Int64 {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
    }

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var cont: CheckedContinuation<URL, Error>?
    private var progress: ((Int64, Int64) -> Void)?
    private var resumeData: Data?
    private var resumeFor: URL?
    private var checkedSpace = false
    private let lock = NSLock()
    private var cancelled = false

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    var canResume: Bool { lock.withLock { resumeData != nil } }

    func cancel() { lock.withLock { cancelled = true }; task?.cancel() }

    /// Downloads to a temp file and returns it. A previous failed download of the same URL resumes if the server allows.
    func download(_ url: URL, allowInsecure: Bool = false, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        try Self.check(url, allowInsecure: allowInsecure)
        return try await withCheckedThrowingContinuation { c in
            lock.lock()
            cancelled = false; checkedSpace = false; self.progress = progress; cont = c
            let t: URLSessionDownloadTask
            if let rd = resumeData, resumeFor == url { t = session.downloadTask(withResumeData: rd) } else { t = session.downloadTask(with: url) }
            resumeData = nil; resumeFor = url; task = t
            lock.unlock()
            t.resume()
        }
    }

    private func finish(_ r: Result<URL, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if !checkedSpace, totalBytesExpectedToWrite > 0 {
            checkedSpace = true
            let free = Self.freeBytes(at: FileManager.default.temporaryDirectory)
            if free < totalBytesExpectedToWrite + 200_000_000 {   // keep ~200 MB headroom
                lock.withLock { cancelled = true; resumeData = nil }
                task?.cancel()
                finish(.failure(DLError.notEnoughSpace(need: totalBytesExpectedToWrite, free: free)))
                return
            }
        }
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let r = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(r.statusCode) { finish(.failure(DLError.http(r.statusCode))); return }
        // The system deletes `location` when this returns: move it now.
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)." + (downloadTask.originalRequest?.url?.pathExtension ?? "mp4"))
        do { try FileManager.default.moveItem(at: location, to: dst); finish(.success(dst)) } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        let was = lock.withLock { cancelled }
        if !was, let rd = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { lock.withLock { resumeData = rd } }
        finish(.failure(was ? DLError.cancelled : error))
    }
}
