import Foundation

/// Per-frame swapped face patches keyed by presentation timestamp (microseconds). This is the cache behind Mode A / B
/// (see specs/03): ~49 KB per face per frame instead of a full swapped frame. An empty array means "frame processed,
/// no face", which matters for rendered-range display.
final class PatchStore {
    private let lock = NSLock()
    private var patches: [Int64: [SwapPatch]] = [:]
    private var keys: [Int64] = []  // sorted
    let frameDurationUs: Int64

    init(frameDurationUs: Int64) { self.frameDurationUs = frameDurationUs }

    static func us(_ seconds: Double) -> Int64 { Int64((seconds * 1_000_000).rounded()) }

    func put(pts: Int64, _ p: [SwapPatch]) {
        lock.lock(); defer { lock.unlock() }
        if patches.updateValue(p, forKey: pts) == nil {
            var lo = 0, hi = keys.count
            while lo < hi { let mid = (lo + hi) / 2; if keys[mid] < pts { lo = mid + 1 } else { hi = mid } }
            keys.insert(pts, at: lo)
        }
    }

    /// Patches for the frame at/just before `pts` if it is within half a frame, else nil.
    func get(pts: Int64) -> [SwapPatch]? {
        lock.lock(); defer { lock.unlock() }
        guard let k = nearestLocked(pts) else { return nil }
        return abs(k - pts) <= frameDurationUs / 2 + 1 ? patches[k] : nil
    }

    /// Patches for the frame DISPLAYED at playhead time `t`: the frame with the greatest key <= t (a player shows frame k
    /// from its PTS until the next one), if it is within one frame duration; nil = not rendered. Use this from the player.
    func get(displayedAt t: Int64) -> [SwapPatch]? {
        lock.lock(); defer { lock.unlock() }
        var lo = 0, hi = keys.count
        while lo < hi { let mid = (lo + hi) / 2; if keys[mid] <= t { lo = mid + 1 } else { hi = mid } }
        guard lo > 0, t - keys[lo - 1] < frameDurationUs * 3 / 2 else { return nil }
        return patches[keys[lo - 1]]
    }

    /// Newest patches at or before `pts` (Mode B: latest available).
    func latest(atOrBefore pts: Int64) -> [SwapPatch]? {
        lock.lock(); defer { lock.unlock() }
        var lo = 0, hi = keys.count
        while lo < hi { let mid = (lo + hi) / 2; if keys[mid] <= pts { lo = mid + 1 } else { hi = mid } }
        var i = lo - 1
        while i >= 0 { if let p = patches[keys[i]], !p.isEmpty { return p }; i -= 1 }
        return nil
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
            if let s = start, k - prev <= frameDurationUs * 3 / 2 { prev = k; _ = s } else {
                if let s = start { out.append(s...(prev + frameDurationUs)) }
                start = k; prev = k
            }
        }
        if let s = start { out.append(s...(prev + frameDurationUs)) }
        return out
    }

    /// Approximate memory use (patch bytes only).
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return patches.values.reduce(0) { $0 + $1.count * (128 * 128 * 3 + 48) } + keys.count * 16 }

    /// Drop frames furthest from `focus` until the store is at most `maxBytes`. Returns how many frames were dropped.
    @discardableResult
    func evict(maxBytes: Int, keepNear focus: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        var total = patches.values.reduce(0) { $0 + $1.count * (128 * 128 * 3 + 48) } + keys.count * 16
        var dropped = 0
        while total > maxBytes, let first = keys.first, let last = keys.last {
            let k = abs(first - focus) >= abs(last - focus) ? first : last
            total -= (patches[k]?.count ?? 0) * (128 * 128 * 3 + 48) + 16
            patches[k] = nil
            if k == first { keys.removeFirst() } else { keys.removeLast() }
            dropped += 1
        }
        return dropped
    }

    // MARK: disk persistence (one file per video/face/decode-size; `identity` guards against stale caches)
    private static let magic: UInt32 = 0x50545331  // "PTS1"

    func save(to url: URL, identity: String) throws {
        lock.lock(); let snapshot = keys.map { ($0, patches[$0]!) }; lock.unlock()
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(Self.magic); put(Int64(frameDurationUs))
        let id = Array(identity.utf8); put(UInt32(id.count)); d.append(contentsOf: id)
        put(UInt32(snapshot.count))
        for (k, ps) in snapshot {
            put(k); put(UInt8(ps.count))
            for p in ps { put(p.M.a); put(p.M.b); put(p.M.tx); put(p.M.c); put(p.M.d); put(p.M.ty); d.append(contentsOf: p.bgr) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: .atomic)
    }

    /// Loads frames from a cache file; returns false (and loads nothing) if it is missing, corrupt or for another identity.
    @discardableResult
    func load(from url: URL, identity: String) -> Bool {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        var o = 0
        func get<T>(_ t: T.Type) -> T? {
            guard o + MemoryLayout<T>.size <= d.count else { return nil }
            defer { o += MemoryLayout<T>.size }
            return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: T.self) }
        }
        guard get(UInt32.self) == Self.magic, get(Int64.self) == frameDurationUs, let n = get(UInt32.self),
              o + Int(n) <= d.count, String(decoding: d[o..<(o + Int(n))], as: UTF8.self) == identity else { return false }
        o += Int(n)
        guard let count = get(UInt32.self) else { return false }
        var loaded: [(Int64, [SwapPatch])] = []
        for _ in 0..<count {
            guard let k = get(Int64.self), let np = get(UInt8.self) else { return false }
            var ps: [SwapPatch] = []
            for _ in 0..<np {
                guard let a = get(Double.self), let b = get(Double.self), let tx = get(Double.self), let c = get(Double.self),
                      let dd = get(Double.self), let ty = get(Double.self), o + 128 * 128 * 3 <= d.count else { return false }
                ps.append(SwapPatch(bgr: [UInt8](d[o..<(o + 128 * 128 * 3)]), M: Affine(a: a, b: b, tx: tx, c: c, d: dd, ty: ty)))
                o += 128 * 128 * 3
            }
            loaded.append((k, ps))
        }
        for (k, ps) in loaded { put(pts: k, ps) }
        return true
    }

    func removeAll() { lock.lock(); patches = [:]; keys = []; lock.unlock() }

    private func nearestLocked(_ pts: Int64) -> Int64? {
        var lo = 0, hi = keys.count
        while lo < hi { let mid = (lo + hi) / 2; if keys[mid] < pts { lo = mid + 1 } else { hi = mid } }
        let a = lo < keys.count ? keys[lo] : nil, b = lo > 0 ? keys[lo - 1] : nil
        switch (a, b) {
        case let (a?, b?): return abs(a - pts) <= abs(b - pts) ? a : b
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
