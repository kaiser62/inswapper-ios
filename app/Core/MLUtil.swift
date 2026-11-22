import CoreML
import Foundation

func halfToFloat(_ h: UInt16) -> Float {
    let s = UInt32(h >> 15) << 31, e = UInt32((h >> 10) & 0x1f), m = UInt32(h & 0x3ff)
    if e == 0 {
        if m == 0 { return Float(bitPattern: s) }
        return (s != 0 ? -1 : 1) * Float(m) * Float(sign: .plus, exponent: -24, significand: 1)
    }
    if e == 31 { return Float(bitPattern: s | 0x7f80_0000 | (m << 13)) }
    return Float(bitPattern: s | ((e + 112) << 23) | (m << 13))
}

extension MLMultiArray {
    /// Logical (C-order) contents as Float. Handles float16/float32 and padded strides (the Neural Engine pads output
    /// strides, which made the old per-element NSNumber path cost ~50 ms per detection on device).
    func toFloats() -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        guard dataType == .float32 || dataType == .float16 else {
            for i in 0..<n { out[i] = self[i].floatValue }
            return out
        }
        let dims = shape.map { $0.intValue }, st = strides.map { $0.intValue }
        let nd = dims.count
        let is16 = dataType == .float16
        let p32 = dataPointer.assumingMemoryBound(to: Float.self)
        let p16 = dataPointer.assumingMemoryBound(to: UInt16.self)
        @inline(__always) func at(_ o: Int) -> Float { is16 ? halfToFloat(p16[o]) : p32[o] }
        var idx = [Int](repeating: 0, count: nd)
        var off = 0
        for i in 0..<n {
            out[i] = at(off)
            var d = nd - 1  // odometer increment, last dim fastest
            while d >= 0 {
                idx[d] += 1; off += st[d]
                if idx[d] < dims[d] { break }
                off -= idx[d] * st[d]; idx[d] = 0; d -= 1
            }
        }
        return out
    }
}
