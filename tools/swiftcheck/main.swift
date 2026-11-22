// Mac harness: runs the Swift pipeline (app/Core) on the local test pair and compares with the Python golden data.
// Local only (face data). Build+run: tools/swiftcheck/run.sh
import CoreML
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])  // tools/models
let test = root.appendingPathComponent("test"), compiled = root.appendingPathComponent("compiled")
try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
for n in ["scrfd", "arcface", "swapper"] where !FileManager.default.fileExists(atPath: compiled.appendingPathComponent(n + ".mlmodelc").path) {
    let c = try MLModel.compileModel(at: root.appendingPathComponent("mlpackages/\(n).mlpackage"))
    try FileManager.default.moveItem(at: c, to: compiled.appendingPathComponent(n + ".mlmodelc"))
}
try? FileManager.default.removeItem(at: compiled.appendingPathComponent("emap.bin"))
try FileManager.default.copyItem(at: root.appendingPathComponent("emap.bin"), to: compiled.appendingPathComponent("emap.bin"))

let g = try JSONSerialization.jsonObject(with: Data(contentsOf: test.appendingPathComponent("golden/golden.json"))) as! [String: [Double]]
func maxDiff(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max()! }

let pipe = try FacePipeline(modelsDirectory: compiled)
let src = try PixelBuf.load(url: test.appendingPathComponent("source.jpeg"))
let tgt = try PixelBuf.load(url: test.appendingPathComponent("target.jpg"))
print("source", PixelBuf.size(src), "target", PixelBuf.size(tgt))

func biggest(_ f: [DetectedFace]) -> DetectedFace { f.max { $0.area < $1.area }! }
let sf = biggest(try pipe.detect(src)), tf = biggest(try pipe.detect(tgt))
print("skps max diff px vs python:", maxDiff(sf.landmarks.flatMap { [$0.x, $0.y] }, g["skps"]!))
print("tkps max diff px vs python:", maxDiff(tf.landmarks.flatMap { [$0.x, $0.y] }, g["tkps"]!))

let M = FaceAlign.estimate(landmarks: tf.landmarks, size: 128)
print("M max diff vs python:", maxDiff([M.a, M.b, M.tx, M.c, M.d, M.ty], g["M"]!))

let lat = try pipe.latent(forSource: src, face: sf)
let gl = g["latent"]!
print("latent cosine vs python:", zip(lat, gl).map { Double($0) * $1 }.reduce(0, +))

var t0 = Date()
let patch = try pipe.swap(frame: tgt, face: tf, latent: lat)
let fake = [UInt8](try Data(contentsOf: test.appendingPathComponent("golden/fake_bgr.bin")))
let mse = zip(patch.bgr, fake).map { pow(Double($0) - Double($1), 2) }.reduce(0, +) / Double(fake.count)
print(String(format: "128px patch PSNR vs python Core ML: %.2f dB", 10 * log10(255 * 255 / max(mse, 1e-9))))

let out = try Compositor.composite(tgt, patches: [patch])
try PixelBuf.writePNG(out, to: test.appendingPathComponent("out_swift.png"))
print("wrote out_swift.png")

// timing (warm)
t0 = Date()
for _ in 0..<5 { _ = try pipe.detect(tgt); _ = try pipe.swap(frame: tgt, face: tf, latent: lat) }
print(String(format: "detect+swap warm on Mac: %.0f ms/frame", Date().timeIntervalSince(t0) / 5 * 1000))
t0 = Date(); _ = try Compositor.composite(tgt, patches: [patch])
print(String(format: "CPU composite: %.0f ms", Date().timeIntervalSince(t0) * 1000))
