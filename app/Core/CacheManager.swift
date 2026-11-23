import Foundation

/// Disk cache bookkeeping for per-video patch caches (one subdirectory per video/face identity).
enum CacheManager {
    static func size(of url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// Newest modification time inside a cache directory (its "last used").
    static func lastUsed(_ dir: URL) -> Date {
        var newest = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let f as URL in en { if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > newest { newest = d } }
        }
        return newest
    }

    static func entries(root: URL) -> [(url: URL, bytes: Int64, used: Date)] {
        let subs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { ($0, size(of: $0), lastUsed($0)) }
    }

    static func totalBytes(root: URL) -> Int64 { size(of: root) }

    /// Deletes least-recently-used cache directories until the total is <= capBytes. `keep` (the one in use) is never deleted.
    /// Returns the number of bytes freed.
    @discardableResult
    static func enforce(root: URL, capBytes: Int64, keep: URL? = nil) -> Int64 {
        var list = entries(root: root).sorted { $0.used < $1.used }
        var total = list.reduce(0) { $0 + $1.bytes }
        var freed: Int64 = 0
        while total > capBytes, let victim = list.first(where: { $0.url.standardizedFileURL != keep?.standardizedFileURL }) {
            try? FileManager.default.removeItem(at: victim.url)
            total -= victim.bytes; freed += victim.bytes
            list.removeAll { $0.url == victim.url }
        }
        return freed
    }

    /// Removes every cache directory except `keep`.
    @discardableResult
    static func clear(root: URL, keep: URL? = nil) -> Int64 { enforce(root: root, capBytes: -1, keep: keep) }
}
