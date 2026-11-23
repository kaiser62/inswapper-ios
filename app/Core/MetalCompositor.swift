import CoreVideo
import Foundation
import Metal

/// GPU paste-back: same analytic mask math as `Compositor` (CPU), as a compute kernel compiled from source at run time.
/// Up to `maxPatches` faces per frame, blended in registers in one dispatch (no read-write textures needed).
final class MetalCompositor {
    static let maxPatches = 4
    struct PatchParams {  // must match the MSL struct
        var m: (Float, Float, Float, Float, Float, Float)
        var scale: Float, erode: Float, isq2: Float, pad: Float
        var x0: Int32, y0: Int32, x1: Int32, y1: Int32
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pso: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var patchRing: [MTLTexture] = []
    private var ringIndex = 0
    private var scratch: (w: Int, h: Int, tex: MTLTexture)?

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct PatchParams { float a, b, tx, c, d, ty; float scale, erode, isq2, pad; int x0, y0, x1, y1; };
    struct Uniforms { int count; };
    inline float erf_approx(float x) {  // Abramowitz-Stegun 7.1.26, |err| < 1.5e-7
        float s = x < 0 ? -1.0 : 1.0, ax = fabs(x);
        float t = 1.0 / (1.0 + 0.3275911 * ax);
        float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-ax * ax);
        return s * y;
    }
    inline float3 fetch(texture2d_array<float, access::read> p, int x, int y, int slice) {
        if (x < 0 || y < 0 || x >= 128 || y >= 128) return float3(0);
        return p.read(uint2(x, y), slice).rgb;
    }
    kernel void paste(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      texture2d_array<float, access::read> patches [[texture(2)]],
                      constant PatchParams* P [[buffer(0)]],
                      constant Uniforms& U [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(gid);
        int x = int(gid.x), y = int(gid.y);
        for (int i = 0; i < U.count; i++) {
            PatchParams q = P[i];
            if (x < q.x0 || x > q.x1 || y < q.y0 || y > q.y1) continue;
            float ax = q.a * x + q.b * y + q.tx, ay = q.c * x + q.d * y + q.ty;
            float d = min(min(ax, 128.0 - ax), min(ay, 128.0 - ay)) / q.scale;
            float z = (d - q.erode) * q.isq2;
            if (z < -3.0) continue;
            float m = z > 3.0 ? 1.0 : 0.5 * (1.0 + erf_approx(z));
            int ix = int(floor(ax)), iy = int(floor(ay));
            float wx = ax - ix, wy = ay - iy;
            float3 v = (fetch(patches, ix, iy, i) * (1 - wx) + fetch(patches, ix + 1, iy, i) * wx) * (1 - wy)
                     + (fetch(patches, ix, iy + 1, i) * (1 - wx) + fetch(patches, ix + 1, iy + 1, i) * wx) * wy;
            c.rgb = m * v + (1 - m) * c.rgb;
        }
        dst.write(c, gid);
    }
    """

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: Self.source, options: nil),
              let fn = lib.makeFunction(name: "paste"),
              let pso = try? dev.makeComputePipelineState(function: fn) else { return nil }
        device = dev; queue = q; self.pso = pso
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .bgra8Unorm; d.width = 128; d.height = 128
        d.arrayLength = Self.maxPatches; d.usage = .shaderRead
        for _ in 0..<3 { guard let t = dev.makeTexture(descriptor: d) else { return nil }; patchRing.append(t) }
    }

    static func params(for p: SwapPatch, width w: Int, height h: Int) -> PatchParams? {
        let M = p.M, IM = M.inverted(), s = M.scale, th = M.angle, S = 128.0
        let corners = [(0.0, 0.0), (S, 0), (S, S), (0, S)].map { IM.apply($0.0, $0.1) }
        let xs = corners.map { $0.0 }, ys = corners.map { $0.1 }
        let mw = xs.max()! - xs.min()!, mh = ys.max()! - ys.min()!
        let ms = Int((mh * mw).squareRoot())
        let k = max(ms / 10, 10), k2 = max(ms / 20, 5)
        let sigma = 0.3 * (Double(2 * k2) * 0.5 - 1) + 0.8
        let e = Double(k) / 2 * (abs(cos(th)) + abs(sin(th)))
        let x0 = max(0, Int(xs.min()!) - 2), x1 = min(w - 1, Int(xs.max()!) + 2)
        let y0 = max(0, Int(ys.min()!) - 2), y1 = min(h - 1, Int(ys.max()!) + 2)
        if x0 > x1 || y0 > y1 { return nil }
        return PatchParams(m: (Float(M.a), Float(M.b), Float(M.tx), Float(M.c), Float(M.d), Float(M.ty)),
                           scale: Float(s), erode: Float(e), isq2: Float(1 / (sigma * 2.0.squareRoot())), pad: 0,
                           x0: Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1))
    }

    func texture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        var ct: CVMetalTexture?
        let (w, h) = PixelBuf.size(pb)
        guard let cache, CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &ct) == kCVReturnSuccess,
              let c = ct, let t = CVMetalTextureGetTexture(c) else { return nil }
        return (t, c)
    }

    /// Encode a paste into `commandBuffer`: `src` and `dst` must be same-size bgra8 textures (dst needs .shaderWrite).
    func encode(src: MTLTexture, dst: MTLTexture, patches: [SwapPatch], commandBuffer cb: MTLCommandBuffer) {
        let use = Array(patches.prefix(Self.maxPatches))
        var ps = use.compactMap { Self.params(for: $0, width: dst.width, height: dst.height) }
        var count = Int32(ps.count)
        if ps.isEmpty { ps = [PatchParams(m: (1, 0, 0, 0, 1, 0), scale: 1, erode: 0, isq2: 1, pad: 0, x0: 1, y0: 1, x1: 0, y1: 0)] }
        let patchTex = patchRing[ringIndex % patchRing.count]; ringIndex += 1   // ring: a frame still in flight keeps its own patches
        // upload only the patches that survived (keeping index alignment with ps)
        var slot = 0
        for p in use where Self.params(for: p, width: dst.width, height: dst.height) != nil {
            var bgra = [UInt8](repeating: 255, count: 128 * 128 * 4)
            for i in 0..<(128 * 128) { bgra[i * 4] = p.bgr[i * 3]; bgra[i * 4 + 1] = p.bgr[i * 3 + 1]; bgra[i * 4 + 2] = p.bgr[i * 3 + 2] }
            patchTex.replace(region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0, slice: slot, withBytes: bgra, bytesPerRow: 128 * 4, bytesPerImage: 128 * 128 * 4)
            slot += 1
        }
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0); enc.setTexture(dst, index: 1); enc.setTexture(patchTex, index: 2)
        enc.setBytes(&ps, length: MemoryLayout<PatchParams>.stride * ps.count, index: 0)
        enc.setBytes(&count, length: 4, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    /// Offline path (export / tests): returns a new BGRA buffer.
    func composite(_ frame: CVPixelBuffer, patches: [SwapPatch]) throws -> CVPixelBuffer {
        let (w, h) = PixelBuf.size(frame)
        let out = try PixelBuf.make(width: w, height: h)
        guard let (s, sk) = texture(frame), let (d, dk) = texture(out), let cb = queue.makeCommandBuffer() else { throw ImagingError.alloc }
        encode(src: s, dst: d, patches: patches, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        _ = (sk, dk)
        return out
    }
}
