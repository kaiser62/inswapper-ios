import Foundation

/// Saved source identities. Per entry: name, creation date, the L2-normalised ArcFace embeddings of each added photo
/// (so photos can be added later and averaged), and an optional small JPEG thumbnail. The source photo itself is never stored.
/// Pure Foundation: UI and ML live elsewhere. Everything stays in `directory` (app data, never in git).
final class FaceLibrary {
    struct Entry: Codable, Equatable { var id: String, name: String, created: Date, photoCount: Int }

    let directory: URL
    private(set) var entries: [Entry] = []
    private let lock = NSLock()
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL), let e = try? JSONDecoder.iso.decode([Entry].self, from: d) { entries = e }
    }

    private func save() {
        if let d = try? JSONEncoder.iso.encode(entries) { try? d.write(to: indexURL, options: .atomic) }
    }
    private func embURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".emb") }
    private func thumbURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".jpg") }

    /// Embeddings are 512 floats each, concatenated.
    func embeddings(id: String) -> [[Float]] {
        guard let d = try? Data(contentsOf: embURL(id)), d.count % (512 * 4) == 0 else { return [] }
        let all = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return stride(from: 0, to: all.count, by: 512).map { Array(all[$0..<$0 + 512]) }
    }
    private func writeEmbeddings(_ e: [[Float]], id: String) {
        var d = Data(); for v in e { v.withUnsafeBytes { d.append(contentsOf: $0) } }
        try? d.write(to: embURL(id), options: .atomic)
    }

    func thumbnail(id: String) -> Data? { try? Data(contentsOf: thumbURL(id)) }

    @discardableResult
    func add(name: String, embedding: [Float], thumbnailJPEG: Data?) -> Entry {
        lock.lock(); defer { lock.unlock() }
        let e = Entry(id: UUID().uuidString, name: name, created: Date(), photoCount: 1)
        writeEmbeddings([Self.normalised(embedding)], id: e.id)
        if let t = thumbnailJPEG { try? t.write(to: thumbURL(e.id), options: .atomic) }
        entries.append(e); save()
        return e
    }

    /// Adds another photo of the same person.
    func addPhoto(id: String, embedding: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = embeddings(id: id); e.append(Self.normalised(embedding))
        writeEmbeddings(e, id: id)
        entries[i].photoCount = e.count; save()
    }

    func rename(id: String, to name: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].name = name; save() }
    }

    func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: embURL(id)); try? FileManager.default.removeItem(at: thumbURL(id)); save()
    }

    /// Mean of the L2-normalised embeddings, re-normalised (apply emap AFTER this).
    static func averaged(_ e: [[Float]]) -> [Float]? {
        guard let f = e.first else { return nil }
        var s = [Float](repeating: 0, count: f.count)
        for v in e { let n = normalised(v); for i in 0..<s.count { s[i] += n[i] } }
        return normalised(s)
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    /// Stable short fingerprint of a latent, for cache identities (the library stores no photo).
    static func fingerprint(_ latent: [Float]) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a over the float bit patterns
        for v in latent { var b = v.bitPattern; for _ in 0..<4 { h = (h ^ UInt64(b & 0xFF)) &* 1099511628211; b >>= 8 } }
        return String(h, radix: 16)
    }
}

private extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
private extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
