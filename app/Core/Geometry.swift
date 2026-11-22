import Foundation

/// 2x3 affine map: (x, y) -> (a*x + b*y + tx, c*x + d*y + ty).
struct Affine {
    var a, b, tx, c, d, ty: Double

    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        (a * x + b * y + tx, c * x + d * y + ty)
    }

    func inverted() -> Affine {
        let det = a * d - b * c
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Affine(a: ia, b: ib, tx: -(ia * tx + ib * ty), c: ic, d: id, ty: -(ic * tx + id * ty))
    }

    /// Uniform scale of a similarity transform.
    var scale: Double { (a * a + c * c).squareRoot() }
    var angle: Double { atan2(c, a) }
}

typealias Point = (x: Double, y: Double)

enum FaceAlign {
    /// ArcFace 112 px landmark template (insightface arcface_dst).
    static let arcface112: [Point] = [
        (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041),
    ]

    /// 112 for ArcFace; 128 for the swapper = the 112 template with x shifted by +8 (NOT scaled), as in
    /// insightface face_align.estimate_norm.
    static func template(size: Int) -> [Point] {
        precondition(size == 112 || size == 128, "unsupported align size")
        return arcface112.map { (size == 128 ? $0.x + 8 : $0.x, $0.y) }
    }

    /// Least-squares similarity transform (rotation + uniform scale + translation, no reflection).
    /// Equals Umeyama / skimage SimilarityTransform for non-degenerate landmarks.
    static func similarity(from src: [Point], to dst: [Point]) -> Affine {
        let n = Double(src.count)
        let msx = src.reduce(0) { $0 + $1.x } / n, msy = src.reduce(0) { $0 + $1.y } / n
        let mdx = dst.reduce(0) { $0 + $1.x } / n, mdy = dst.reduce(0) { $0 + $1.y } / n
        var num1 = 0.0, num2 = 0.0, den = 0.0
        for i in 0..<src.count {
            let sx = src[i].x - msx, sy = src[i].y - msy
            let dx = dst[i].x - mdx, dy = dst[i].y - mdy
            num1 += sx * dx + sy * dy
            num2 += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        let a = num1 / den, b = num2 / den
        return Affine(a: a, b: -b, tx: mdx - (a * msx - b * msy), c: b, d: a, ty: mdy - (b * msx + a * msy))
    }

    /// Landmarks (image px) -> aligned `size` px crop transform.
    static func estimate(landmarks: [Point], size: Int) -> Affine {
        similarity(from: landmarks, to: template(size: size))
    }
}
