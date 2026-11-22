import Metal
guard let dev = MTLCreateSystemDefaultDevice() else { print("NO METAL DEVICE"); exit(1) }
print("device:", dev.name)
let src = "#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device float* o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = float(i) * 2.0; }"
do {
    let lib = try dev.makeLibrary(source: src, options: nil)
    let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
    let buf = dev.makeBuffer(length: 16 * 4, options: .storageModeShared)!
    let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: 16, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let p = buf.contents().bindMemory(to: Float.self, capacity: 16)
    print("runtime-compiled kernel result[5] =", p[5], "(expect 10)")
} catch { print("FAILED:", error) }
