import CoreVideo
import CoreGraphics
import ImageIO
import Foundation

enum ImagingError: Error { case decode, alloc }

/// BGRA `CVPixelBuffer` helpers. All pipeline stages are frame-in / frame-out on these buffers.
enum PixelBuf {
    static func make(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let out = pb else { throw ImagingError.alloc }
        return out
    }

    /// Run `body(basePointer, width, height, bytesPerRow)` with the buffer locked.
    static func withBytes<T>(_ pb: CVPixelBuffer, readOnly: Bool = true,
                             _ body: (UnsafeMutablePointer<UInt8>, Int, Int, Int) throws -> T) rethrows -> T {
        CVPixelBufferLockBaseAddress(pb, readOnly ? .readOnly : [])
        defer { CVPixelBufferUnlockBaseAddress(pb, readOnly ? .readOnly : []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        return try body(base, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetBytesPerRow(pb))
    }

    static func size(_ pb: CVPixelBuffer) -> (w: Int, h: Int) { (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)) }

    /// Decode an image file (applies EXIF orientation), optionally limiting the longest side.
    static func load(url: URL, maxSide: Int = 4096) throws -> CVPixelBuffer {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImagingError.decode }
        return try load(source: src, maxSide: maxSide)
    }

    /// Same, from encoded bytes (e.g. PhotosPicker data). Never go through UIImage.cgImage: it drops EXIF rotation.
    static func load(data: Data, maxSide: Int = 4096) throws -> CVPixelBuffer {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImagingError.decode }
        return try load(source: src, maxSide: maxSide)
    }

    private static func load(source src: CGImageSource, maxSide: Int) throws -> CVPixelBuffer {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw ImagingError.decode }
        return try from(cgImage: cg)
    }

    static func from(cgImage cg: CGImage) throws -> CVPixelBuffer {
        let pb = try make(width: cg.width, height: cg.height)
        try withBytes(pb, readOnly: false) { base, w, h, bpr in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
            else { throw ImagingError.alloc }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pb
    }

    static func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        withBytes(pb) { base, w, h, bpr in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
            return ctx.makeImage()  // copies
        }
    }

    static func writePNG(_ pb: CVPixelBuffer, to url: URL) throws {
        guard let cg = cgImage(from: pb),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw ImagingError.decode }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImagingError.decode }
    }

    static func writeJPEG(_ pb: CVPixelBuffer, to url: URL, quality: Double = 0.95) throws {
        guard let cg = cgImage(from: pb),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw ImagingError.decode }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImagingError.decode }
    }

    /// Like cv2.warpAffine(src, M, (size, size)) with INTER_LINEAR and constant-0 border: `M` maps src -> dst.
    static func warp(_ src: CVPixelBuffer, M: Affine, size: Int) throws -> CVPixelBuffer {
        let dst = try make(width: size, height: size)
        let inv = M.inverted()
        withBytes(src) { sp, sw, sh, sbpr in
            withBytes(dst, readOnly: false) { dp, _, _, dbpr in
                for y in 0..<size {
                    let row = dp + y * dbpr
                    for x in 0..<size {
                        let (fx, fy) = inv.apply(Double(x), Double(y))
                        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
                        let wx = fx - Double(x0), wy = fy - Double(y0)
                        for ch in 0..<3 {
                            func px(_ xx: Int, _ yy: Int) -> Double {
                                (xx < 0 || yy < 0 || xx >= sw || yy >= sh) ? 0 : Double(sp[yy * sbpr + xx * 4 + ch])
                            }
                            let v = (px(x0, y0) * (1 - wx) + px(x0 + 1, y0) * wx) * (1 - wy)
                                + (px(x0, y0 + 1) * (1 - wx) + px(x0 + 1, y0 + 1) * wx) * wy
                            row[x * 4 + ch] = UInt8(max(0, min(255, v.rounded())))
                        }
                        row[x * 4 + 3] = 255
                    }
                }
            }
        }
        return dst
    }

    /// SCRFD input: resize keeping aspect to fit 640 (top-left placement, zero padding). Returns the buffer and the
    /// scale factor (resized / original). Mirrors insightface (cv2.resize INTER_LINEAR).
    static func letterbox(_ src: CVPixelBuffer, size: Int = 640) throws -> (CVPixelBuffer, Double) {
        let (w, h) = Self.size(src)
        let r = Double(h) / Double(w)
        let (nw, nh) = r > 1 ? (Int(Double(size) / r), size) : (size, Int(Double(size) * r))
        let out = try make(width: size, height: size)
        withBytes(out, readOnly: false) { dp, _, _, dbpr in
            for y in 0..<size { memset(dp + y * dbpr, 0, size * 4) }
        }
        let fx = Double(w) / Double(nw), fy = Double(h) / Double(nh)
        withBytes(src) { sp, sw, sh, sbpr in
            withBytes(out, readOnly: false) { dp, _, _, dbpr in
                for y in 0..<nh {
                    let sy = max(0, (Double(y) + 0.5) * fy - 0.5)
                    let y0 = min(Int(sy), sh - 1), y1 = min(y0 + 1, sh - 1), wy = sy - Double(y0)
                    for x in 0..<nw {
                        let sx = max(0, (Double(x) + 0.5) * fx - 0.5)
                        let x0 = min(Int(sx), sw - 1), x1 = min(x0 + 1, sw - 1), wx = sx - Double(x0)
                        for ch in 0..<3 {
                            let p00 = Double(sp[y0 * sbpr + x0 * 4 + ch]), p01 = Double(sp[y0 * sbpr + x1 * 4 + ch])
                            let p10 = Double(sp[y1 * sbpr + x0 * 4 + ch]), p11 = Double(sp[y1 * sbpr + x1 * 4 + ch])
                            let v = (p00 * (1 - wx) + p01 * wx) * (1 - wy) + (p10 * (1 - wx) + p11 * wx) * wy
                            dp[y * dbpr + x * 4 + ch] = UInt8(max(0, min(255, v.rounded())))
                        }
                        dp[y * dbpr + x * 4 + 3] = 255
                    }
                }
            }
        }
        return (out, Double(nh) / Double(h))
    }
}
