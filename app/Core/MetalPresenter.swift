import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Draws raw video frames with the face patches pasted on, into any bgra8 texture (an MTKView drawable or an offscreen
/// texture). At most 3 frames are in flight; when the GPU is behind, `present` returns false (the caller skips the tick).
final class MetalPresenter {
    let compositor: MetalCompositor
    private let inflight = DispatchSemaphore(value: 3)
    private(set) var presented = 0, skipped = 0
    private let lock = NSLock()

    init?() { guard let c = MetalCompositor() else { return nil }; compositor = c }

    var device: MTLDevice { compositor.device }

    /// `dst` must match the frame size and allow shader writes (for an MTKView: framebufferOnly = false).
    @discardableResult
    func present(frame: CVPixelBuffer, patches: [SwapPatch], to dst: MTLTexture, drawable: MTLDrawable? = nil, completion: (() -> Void)? = nil) -> Bool {
        guard inflight.wait(timeout: .now()) == .success else { lock.lock(); skipped += 1; lock.unlock(); return false }
        guard let (src, keep) = compositor.texture(frame), let cb = compositor.queue.makeCommandBuffer() else { inflight.signal(); return false }
        compositor.encode(src: src, dst: dst, patches: patches, commandBuffer: cb)
        if let d = drawable { cb.present(d) }
        cb.addCompletedHandler { [inflight] _ in _ = keep; inflight.signal(); completion?() }
        cb.commit()
        lock.lock(); presented += 1; lock.unlock()
        return true
    }
}
