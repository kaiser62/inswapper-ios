// Synthetic unit tests for app/Core (no face data, no models). Run in CI and locally:
//   swiftc app/Core/*.swift tools/ci-tests/main.swift -o build/coretests && build/coretests
import CoreVideo
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL:", msg) } else { print("ok:", msg) } }
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

// similarity round trip with made-up points
let src: [Point] = [(10, 20), (60, 18), (35, 50), (15, 80), (58, 83)]
let th = 0.4, sc = 1.7, tx = 33.0, ty = -12.0
let truth = Affine(a: sc * cos(th), b: -sc * sin(th), tx: tx, c: sc * sin(th), d: sc * cos(th), ty: ty)
let dst: [Point] = src.map { let r = truth.apply($0.x, $0.y); return (x: r.0, y: r.1) }
let est = FaceAlign.similarity(from: src, to: dst)
check(near(est.a, truth.a) && near(est.b, truth.b) && near(est.c, truth.c) && near(est.d, truth.d) && near(est.tx, tx) && near(est.ty, ty), "similarity recovers a known transform")
check(near(est.scale, sc) && near(est.angle, th), "scale/angle accessors")
let noisy = dst.enumerated().map { ($0.element.x + (Double($0.offset) - 2) * 0.01, $0.element.y) }
let en = FaceAlign.similarity(from: src, to: noisy)
check(abs(en.scale - sc) < 0.02, "similarity stable under small noise")

// inverse
let inv = truth.inverted()
let p = truth.apply(7, 9), q = inv.apply(p.0, p.1)
check(near(q.0, 7) && near(q.1, 9), "affine inverse round trip")

// templates
let t112 = FaceAlign.template(size: 112), t128 = FaceAlign.template(size: 128)
check(t128.indices.allSatisfy { near(t128[$0].x, t112[$0].x + 8) && near(t128[$0].y, t112[$0].y) }, "128 template = 112 template with x + 8")

// NMS
func face(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ s: Float) -> DetectedFace {
    DetectedFace(x1: x1, y1: y1, x2: x2, y2: y2, score: s, landmarks: [])
}
let kept = FacePipeline.nms([face(0, 0, 100, 100, 0.9), face(5, 5, 105, 105, 0.8), face(300, 300, 400, 400, 0.7)], iou: 0.4)
check(kept.count == 2 && kept[0].score == 0.9 && kept[1].score == 0.7, "NMS drops the overlapping lower score, keeps the distant one")

// half floats
check(halfToFloat(0x3C00) == 1 && halfToFloat(0xC000) == -2 && halfToFloat(0x0000) == 0, "halfToFloat basic")
check(halfToFloat(0x7C00) == .infinity && halfToFloat(0x7E00).isNaN, "halfToFloat inf/nan")
check(abs(halfToFloat(0x0001) - 5.9604645e-8) < 1e-12 && halfToFloat(0x3555) > 0.333 && halfToFloat(0x3555) < 0.334, "halfToFloat subnormal / 1/3")

// letterbox geometry (landscape + portrait)
func solid(_ w: Int, _ h: Int, _ v: UInt8) -> CVPixelBuffer {
    let pb = try! PixelBuf.make(width: w, height: h)
    PixelBuf.withBytes(pb, readOnly: false) { b, w, h, bpr in
        for y in 0..<h { for x in 0..<w { for c in 0..<4 { b[y * bpr + x * 4 + c] = v } } }
    }
    return pb
}
let (lbL, sL) = try! PixelBuf.letterbox(solid(200, 100, 255))
check(near(sL, 3.2), "landscape letterbox scale")
PixelBuf.withBytes(lbL) { b, _, _, bpr in
    check(b[10 * bpr + 10 * 4] == 255 && b[400 * bpr + 10 * 4] == 0 && b[10 * bpr + 10 * 4 + 3] == 255, "landscape: content top-left, zero padding below")
}
let (lbP, sP) = try! PixelBuf.letterbox(solid(100, 200, 255))
check(near(sP, 3.2), "portrait letterbox scale")
PixelBuf.withBytes(lbP) { b, _, _, bpr in
    check(b[10 * bpr + 10 * 4] == 255 && b[10 * bpr + 400 * 4] == 0, "portrait: content top-left, zero padding right")
}

// warp identity
let wsrc = solid(128, 128, 77)
let w = try! PixelBuf.warp(wsrc, M: Affine(a: 1, b: 0, tx: 0, c: 0, d: 1, ty: 0), size: 64)
PixelBuf.withBytes(w) { b, _, _, bpr in check(b[30 * bpr + 30 * 4] == 77, "warp identity keeps pixels") }

// compositor on a solid patch: square placed at x,y in 50..178 (scale 1)
let target = solid(300, 300, 100)
let patch = SwapPatch(bgr: (0..<(128 * 128)).flatMap { _ in [UInt8(10), 200, 30] }, M: Affine(a: 1, b: 0, tx: -50, c: 0, d: 1, ty: -50))
let comp = try! Compositor.composite(target, patches: [patch])
PixelBuf.withBytes(comp) { b, _, _, bpr in
    func px(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(b[y * bpr + x * 4 + c]) }
    check(px(114, 114, 0) == 10 && px(114, 114, 1) == 200 && px(114, 114, 2) == 30, "compositor: centre takes the patch colour")
    check(px(10, 10, 0) == 100 && px(290, 290, 1) == 100, "compositor: outside the face is untouched")
    var prev = 0, mono = true
    for x in 50..<114 { let v = px(x, 114, 1); if v < prev { mono = false }; prev = v }
    check(mono && px(52, 114, 1) < 120, "compositor: mask feathers smoothly inward from the edge")
}
check(true, "(target buffer not mutated)"); PixelBuf.withBytes(target) { b, _, _, bpr in check(b[114 * bpr + 114 * 4 + 1] == 100, "composite returns a new buffer") }

// strided MLMultiArray read (padded rows, like the Neural Engine output)
import CoreML
let padded = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4)
for r in 0..<2 { for c in 0..<4 { padded[r * 4 + c] = c < 3 ? Float(r * 10 + c) : -999 } }
let ma = try! MLMultiArray(dataPointer: padded, shape: [2, 3], dataType: .float32, strides: [4, 1])
check(ma.toFloats() == [0, 1, 2, 10, 11, 12], "toFloats honours padded strides")
let h16 = UnsafeMutablePointer<UInt16>.allocate(capacity: 2 * 2 * 4)
for i in 0..<16 { h16[i] = 0x3C00 }  // 1.0
let mb = try! MLMultiArray(dataPointer: h16, shape: [1, 2, 3], dataType: .float16, strides: [8, 4, 1])
check(mb.toFloats() == [Float](repeating: 1, count: 6), "toFloats float16 3-D strided")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
