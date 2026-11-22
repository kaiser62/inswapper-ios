// Mac benchmark: result-file encode / thumbnail / viewer decode cost on a 12 MP buffer (no face data: synthetic gradient).
import CoreVideo
import Foundation
import ImageIO

func t(_ name: String, _ f: () throws -> Void) rethrows { let s = Date(); try f(); print(String(format: "%-34@ %6.0f ms", name as NSString, Date().timeIntervalSince(s) * 1000)) }
let pb = try PixelBuf.make(width: 4032, height: 3024)
PixelBuf.withBytes(pb, readOnly: false) { b, w, h, bpr in
    for y in 0..<h { for x in 0..<w { let o = y * bpr + x * 4; b[o] = UInt8(x & 255); b[o + 1] = UInt8((x + y) / 16 & 255); b[o + 2] = UInt8(y & 255); b[o + 3] = 255 } }
}
let dir = FileManager.default.temporaryDirectory
let png = dir.appendingPathComponent("b.png"), jpg = dir.appendingPathComponent("b.jpg")
t("cgImage(from: buffer)") { _ = PixelBuf.cgImage(from: pb) }
try t("writePNG 4032x3024") { try PixelBuf.writePNG(pb, to: png) }
try t("writeJPEG q0.95") { try PixelBuf.writeJPEG(pb, to: jpg, quality: 0.95) }
print("sizes MB: png", (try FileManager.default.attributesOfItem(atPath: png.path)[.size] as! Int) / 1_000_000, "jpg", (try FileManager.default.attributesOfItem(atPath: jpg.path)[.size] as! Int) / 1_000_000)
func decode(_ u: URL, _ side: Int) -> CGImage? {
    let src = CGImageSourceCreateWithURL(u as CFURL, nil)!
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}
t("PNG  -> 400px thumb") { _ = decode(png, 400) }
t("JPEG -> 400px thumb") { _ = decode(jpg, 400) }
t("PNG  -> 2400px (viewer)") { _ = decode(png, 2400) }
t("JPEG -> 2400px (viewer)") { _ = decode(jpg, 2400) }
