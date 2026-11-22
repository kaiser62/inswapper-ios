import CoreVideo
import Foundation

/// CPU paste-back (Phase 1). Same math the Metal compositor will use in Phase 2: patch sampled at M(x, y),
/// mask = Gaussian-blurred eroded warped square, computed analytically from M (matches insightface's
/// erode+blur mask to ~57 dB PSNR on a real pair; see tools/mask_check.py).
enum Compositor {
    static func composite(_ target: CVPixelBuffer, patches: [SwapPatch]) throws -> CVPixelBuffer {
        let (w, h) = PixelBuf.size(target)
        let out = try PixelBuf.make(width: w, height: h)
        PixelBuf.withBytes(target) { sp, _, _, sbpr in
            PixelBuf.withBytes(out, readOnly: false) { dp, _, _, dbpr in
                for y in 0..<h { memcpy(dp + y * dbpr, sp + y * sbpr, w * 4) }
                for p in patches { blend(p, into: dp, width: w, height: h, bpr: dbpr) }
            }
        }
        return out
    }

    static func blend(_ p: SwapPatch, into dp: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, bpr: Int) {
        let M = p.M, IM = M.inverted(), s = M.scale, th = M.angle, S = 128.0
        let corners = [(0.0, 0.0), (S, 0), (S, S), (0, S)].map { IM.apply($0.0, $0.1) }
        let xs = corners.map { $0.0 }, ys = corners.map { $0.1 }
        let mw = xs.max()! - xs.min()!, mh = ys.max()! - ys.min()!
        let ms = Int((mh * mw).squareRoot())
        let k = max(ms / 10, 10), k2 = max(ms / 20, 5)
        let sigma = 0.3 * (Double(2 * k2) * 0.5 - 1) + 0.8
        let e = Double(k) / 2 * (abs(cos(th)) + abs(sin(th)))  // inward shift from box erosion
        let x0 = max(0, Int(xs.min()!) - 2), x1 = min(w - 1, Int(xs.max()!) + 2)
        let y0 = max(0, Int(ys.min()!) - 2), y1 = min(h - 1, Int(ys.max()!) + 2)
        if x0 > x1 || y0 > y1 { return }
        let isq2 = 1 / (sigma * 2.0.squareRoot())
        p.bgr.withUnsafeBufferPointer { patch in
            func px(_ xx: Int, _ yy: Int, _ ch: Int) -> Double {
                (xx < 0 || yy < 0 || xx >= 128 || yy >= 128) ? 0 : Double(patch[(yy * 128 + xx) * 3 + ch])
            }
            for y in y0...y1 {
                for x in x0...x1 {
                    let (ax, ay) = M.apply(Double(x), Double(y))
                    let d = min(min(ax, S - ax), min(ay, S - ay)) / s
                    let z = (d - e) * isq2
                    if z < -3 { continue }
                    let m = z > 3 ? 1.0 : 0.5 * (1 + erf(z))
                    let ix = Int(floor(ax)), iy = Int(floor(ay)), wx = ax - Double(ix), wy = ay - Double(iy)
                    let o = y * bpr + x * 4
                    for ch in 0..<3 {
                        let v = (px(ix, iy, ch) * (1 - wx) + px(ix + 1, iy, ch) * wx) * (1 - wy)
                            + (px(ix, iy + 1, ch) * (1 - wx) + px(ix + 1, iy + 1, ch) * wx) * wy
                        dp[o + ch] = UInt8(max(0, min(255, m * v + (1 - m) * Double(dp[o + ch]))))
                    }
                }
            }
        }
    }
}
