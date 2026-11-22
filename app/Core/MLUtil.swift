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
    /// Logical (C-order) contents as Float, handling float16/float32 and padded strides.
    func toFloats() -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        var expected = 1, contiguous = true
        for i in stride(from: shape.count - 1, through: 0, by: -1) {
            if strides[i].intValue != expected { contiguous = false }
            expected *= shape[i].intValue
        }
        if contiguous {
            switch dataType {
            case .float32:
                let p = dataPointer.bindMemory(to: Float.self, capacity: n)
                for i in 0..<n { out[i] = p[i] }
                return out
            case .float16:
                let p = dataPointer.bindMemory(to: UInt16.self, capacity: n)
                for i in 0..<n { out[i] = halfToFloat(p[i]) }
                return out
            default: break
            }
        }
        for i in 0..<n { out[i] = self[i].floatValue }
        return out
    }
}
