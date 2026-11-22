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
