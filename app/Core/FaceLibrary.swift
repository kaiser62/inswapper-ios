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

    // MARK: backup (a user-initiated file; contains face-derived numbers, keep it private)
    private struct Backup: Codable { var version = 1; var items: [Item]
        struct Item: Codable { var entry: Entry; var embeddings: Data; var thumb: Data? } }

    func exportData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        let items = entries.map { e in Backup.Item(entry: e, embeddings: (try? Data(contentsOf: embURL(e.id))) ?? Data(), thumb: try? Data(contentsOf: thumbURL(e.id))) }
        return try? JSONEncoder.iso.encode(Backup(items: items))
    }

    /// Adds every identity from a backup (new ids; nothing is overwritten). Returns how many were added.
    @discardableResult
    func importData(_ d: Data) -> Int {
        guard let b = try? JSONDecoder.iso.decode(Backup.self, from: d) else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for it in b.items where it.embeddings.count >= 512 * 4 && it.embeddings.count % (512 * 4) == 0 {
            var e = it.entry; e.id = UUID().uuidString
            try? it.embeddings.write(to: embURL(e.id), options: .atomic)
            if let t = it.thumb { try? t.write(to: thumbURL(e.id), options: .atomic) }
            entries.append(e); n += 1
        }
        save(); return n
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
        return n > 0 && abs(n - 1) > 1e-6 ? v.map { $0 / n } : v   // already unit length: unchanged, so normalising twice is bit-identical
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
