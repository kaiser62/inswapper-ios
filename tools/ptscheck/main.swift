// Prints the first PTS values VideoReader yields from various start times (keying check). Usage: ptscheck <clip>
import Foundation
func main() async throws {
    let r = try await VideoReader(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("natural size/transform:", try await r.track.load(.naturalSize), try await r.track.load(.preferredTransform))
    func keys(_ s: Double, _ n: Int) throws -> [Int64] { var o: [Int64] = []; try r.read(from: s) { _, p in o.append(p); return o.count < n }; return o }
    let all = Set(try keys(0, 90)), mid = try keys(1.0, 30) + keys(2.3, 20)
    print("keys from mid-seeks are a subset of the render-from-0 grid:", mid.allSatisfy { all.contains($0) || $0 > (all.max() ?? 0) }, "(checked \(mid.count))")
    for s in [0.0, 1.0, 1.02, 1.5] {
        var out: [Int64] = []
        try r.read(from: s) { _, p in out.append(p); return out.count < 4 }
        print("from", s, out)
    }
}
let sem = DispatchSemaphore(value: 0)
Task { do { try await main() } catch { print("ERROR", error) }; sem.signal() }
sem.wait()
