import Foundation

/// Per-frame swapped face patches keyed by presentation timestamp (microseconds). This is the cache behind Mode A / B
/// (see specs/03): ~49 KB per face per frame instead of a full swapped frame. An empty array means "frame processed,
/// no face", which matters for rendered-range display.
///
/// Storage: the key index is always in RAM (tiny) and is the truth for `has` / `renderedRanges`. Patch bytes live in RAM
/// per 64-frame chunk. With a directory attached (Mode A), chunks are saved to disk and may be evicted from RAM (furthest
/// from the playhead first) and are paged back in on demand, so eviction never forgets a rendered frame. Without a
/// directory (Mode B) eviction simply forgets the frames.
final class PatchStore {
    static let chunkFrames: Int64 = 64
    private let lock = NSLock()
    private var patches: [Int64: [SwapPatch]] = [:]
    private var keys: [Int64] = []          // sorted, every known frame (resident or paged out)
    private var resident = Set<Int64>()     // chunk ids whose patches are in RAM
    private var dirty = Set<Int64>()        // resident chunks changed since last written
    private var onDisk = Set<Int64>()       // chunk ids that have a file
    private var dir: URL?
    let frameDurationUs: Int64

    init(frameDurationUs: Int64) { self.frameDurationUs = frameDurationUs }

    static func us(_ seconds: Double) -> Int64 { Int64((seconds * 1_000_000).rounded()) }
    private func chunk(_ k: Int64) -> Int64 { k >= 0 ? k / (frameDurationUs * Self.chunkFrames) : -1 - ((-k - 1) / (frameDurationUs * Self.chunkFrames)) }

    // MARK: basic access
    func put(pts: Int64, _ p: [SwapPatch]) {
        lock.lock(); defer { lock.unlock() }
        let c = chunk(pts)
        ensureResidentLocked(c)
        if patches.updateValue(p, forKey: pts) == nil, !containsLocked(pts) { insertKeyLocked(pts) }
        resident.insert(c); dirty.insert(c)
    }

    /// Patches for the frame at/just before `pts` if it is within half a frame, else nil.
    func get(pts: Int64) -> [SwapPatch]? {
        lock.lock(); defer { lock.unlock() }
        guard let k = nearestLocked(pts), abs(k - pts) <= frameDurationUs / 2 + 1 else { return nil }
        return fetchLocked(k)
    }

    /// Patches for the frame DISPLAYED at playhead time `t`: the frame with the greatest key <= t (a player shows frame k
    /// from its PTS until the next one), if it is within 1.5 frame durations; nil = not rendered. Use this from the player.
    func get(displayedAt t: Int64) -> [SwapPatch]? {
        lock.lock(); defer { lock.unlock() }
        let i = upperBoundLocked(t)
        guard i > 0, t - keys[i - 1] < frameDurationUs * 3 / 2 else { return nil }
        return fetchLocked(keys[i - 1])
    }

    /// Mode B: the newest patches at or before `pts`, if that frame is at most `maxAge` microseconds old. An EMPTY array
    /// means the newest frame had no face (do not paste an older one: it would be a ghost). nil = nothing recent.
    func latest(atOrBefore pts: Int64, maxAge: Int64 = 600_000) -> [SwapPatch]? {
        lock.lock(); defer { lock.unlock() }
        let i = upperBoundLocked(pts)
        guard i > 0, pts - keys[i - 1] <= maxAge else { return nil }
        return fetchLocked(keys[i - 1])
    }

    func has(pts: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let k = nearestLocked(pts) else { return false }
        return abs(k - pts) <= frameDurationUs / 2 + 1
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return keys.count }

    /// Contiguous rendered ranges (frames closer than 1.5 frame durations are joined), in microseconds.
    func renderedRanges() -> [ClosedRange<Int64>] {
        lock.lock(); defer { lock.unlock() }
        var out: [ClosedRange<Int64>] = []
        var start: Int64?, prev: Int64 = 0
        for k in keys {
            if start != nil, k - prev <= frameDurationUs * 3 / 2 { prev = k } else {
                if let s = start { out.append(s...(prev + frameDurationUs)) }
                start = k; prev = k
            }
        }
        if let s = start { out.append(s...(prev + frameDurationUs)) }
        return out
    }

    // MARK: memory cap
    private static let frameBytes = 128 * 128 * 3 + 48
    /// Approximate RAM use (resident patch bytes only).
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return bytesLocked() }
    private func bytesLocked() -> Int { patches.values.reduce(0) { $0 + $1.count * Self.frameBytes + 16 } }

    /// Drop resident chunks furthest from `focus` until RAM use is at most `maxBytes`. With a directory attached the
    /// chunk is written first and its keys stay known (paged back in on demand); without one the frames are forgotten.
    /// Returns the number of frames dropped from RAM.
    @discardableResult
    func evict(maxBytes: Int, keepNear focus: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        var dropped = 0
        let span = frameDurationUs * Self.chunkFrames
        while bytesLocked() > maxBytes {
            guard let c = resident.max(by: { abs($0 * span + span / 2 - focus) < abs($1 * span + span / 2 - focus) }) else { break }
            if dir != nil { if dirty.contains(c) { writeChunkLocked(c) } }
            let ks = keys.filter { chunk($0) == c }
            for k in ks { patches[k] = nil; dropped += 1 }
            resident.remove(c); dirty.remove(c)
            if dir == nil || !onDisk.contains(c) { keys.removeAll { chunk($0) == c } }
        }
        return dropped
    }

    // MARK: disk persistence
    private static let magic: UInt32 = 0x50545332  // "PTS2"

    /// Attach a cache directory. `identity` (video | source face | decode size) guards against stale caches: a different
    /// identity or frame duration wipes the directory. Loads only the key index; patch bytes page in on demand.
    /// Returns the number of frames already rendered on disk.
    @discardableResult
    func attach(directory: URL, identity: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = directory.appendingPathComponent("meta.txt"), want = "\(identity)\n\(frameDurationUs)"
        if (try? String(contentsOf: meta, encoding: .utf8)) != want {
            for f in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] { try? fm.removeItem(at: directory.appendingPathComponent(f)) }
            try? want.write(to: meta, atomically: true, encoding: .utf8)
        }
        dir = directory
        for f in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where f.hasPrefix("c") && f.hasSuffix(".bin") {
            guard let id = Int64(f.dropFirst().dropLast(4)), let table = readTable(directory.appendingPathComponent(f)) else {
                try? fm.removeItem(at: directory.appendingPathComponent(f)); continue }
            onDisk.insert(id)
            for (k, _) in table where !containsLocked(k) { insertKeyLocked(k) }
        }
        return keys.count
    }

    /// Write every dirty resident chunk (call on pause / background / when a render pass ends).
    func flush() {
        lock.lock(); defer { lock.unlock() }
        for c in dirty { writeChunkLocked(c) }
        dirty.removeAll()
    }

    private func fileLocked(_ c: Int64) -> URL? { dir?.appendingPathComponent("c\(c).bin") }

    private func writeChunkLocked(_ c: Int64) {
        guard let url = fileLocked(c) else { return }
        let ks = keys.filter { chunk($0) == c && patches[$0] != nil }
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(Self.magic); put(UInt32(ks.count))
        for k in ks { put(k); put(UInt8(patches[k]!.count)) }
        for k in ks { for p in patches[k]! { put(p.M.a); put(p.M.b); put(p.M.tx); put(p.M.c); put(p.M.d); put(p.M.ty); d.append(contentsOf: p.bgr) } }
        if (try? d.write(to: url, options: .atomic)) != nil { onDisk.insert(c); dirty.remove(c) }
    }

    private func readTable(_ url: URL) -> [(Int64, Int)]? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count >= 8 else { return nil }
        var o = 0
        func get<T>(_ t: T.Type) -> T? {
            guard o + MemoryLayout<T>.size <= d.count else { return nil }
            defer { o += MemoryLayout<T>.size }
            return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: T.self) }
        }
        guard get(UInt32.self) == Self.magic, let n = get(UInt32.self) else { return nil }
        var t: [(Int64, Int)] = [], need = 8 + Int(n) * 9
        for _ in 0..<n { guard let k = get(Int64.self), let np = get(UInt8.self) else { return nil }; t.append((k, Int(np))); need += Int(np) * (48 + 128 * 128 * 3) }
        return need == d.count ? t : nil
    }

    private func ensureResidentLocked(_ c: Int64) {
        if resident.contains(c) || !onDisk.contains(c) { return }
        guard let url = fileLocked(c), let table = readTable(url), let d = try? Data(contentsOf: url) else { return }
        var o = 8 + table.count * 9
        for (k, np) in table {
            var ps: [SwapPatch] = []
            for _ in 0..<np {
                func dbl(_ i: Int) -> Double { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o + i * 8, as: Double.self) } }
                let M = Affine(a: dbl(0), b: dbl(1), tx: dbl(2), c: dbl(3), d: dbl(4), ty: dbl(5))
                o += 48
                ps.append(SwapPatch(bgr: [UInt8](d[o..<(o + 128 * 128 * 3)]), M: M)); o += 128 * 128 * 3
            }
            patches[k] = ps
        }
        resident.insert(c)
    }

    private func fetchLocked(_ k: Int64) -> [SwapPatch]? {
        if patches[k] == nil { ensureResidentLocked(chunk(k)) }
        return patches[k]
    }

    func removeAll() { lock.lock(); patches = [:]; keys = []; resident = []; dirty = []; onDisk = []; lock.unlock() }

    // MARK: sorted-key helpers
    private func upperBoundLocked(_ t: Int64) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi { let mid = (lo + hi) / 2; if keys[mid] <= t { lo = mid + 1 } else { hi = mid } }
        return lo
    }
    private func containsLocked(_ k: Int64) -> Bool { let i = upperBoundLocked(k); return i > 0 && keys[i - 1] == k }
    private func insertKeyLocked(_ k: Int64) { keys.insert(k, at: upperBoundLocked(k)) }
    private func nearestLocked(_ pts: Int64) -> Int64? {
        let i = upperBoundLocked(pts)
        let b = i > 0 ? keys[i - 1] : nil, a = i < keys.count ? keys[i] : nil
        switch (a, b) {
        case let (a?, b?): return abs(a - pts) < abs(b - pts) ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

final class CancelToken {
    private let lock = NSLock(); private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}
