import Foundation
import CoreML
import ZIPFoundation

struct Manifest: Decodable { let format_version: Int }

struct ImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ModelStore {
    static let names = ["scrfd", "arcface", "swapper"]

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func compiledURL(_ name: String) -> URL {
        dir.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
    }

    static var isInstalled: Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: compiledURL($0).path) }
    }

    /// Imports models.zip picked from Files: copy -> unzip -> validate manifest -> compile on device -> store.
    static func importZip(_ picked: URL, log: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let work = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        log("copying zip…")
        let local = work.appendingPathComponent("models.zip")
        try fm.copyItem(at: picked, to: local)
        let unz = work.appendingPathComponent("unz", isDirectory: true)
        try fm.createDirectory(at: unz, withIntermediateDirectories: true)
        log("unzipping…")
        try fm.unzipItem(at: local, to: unz)
        try? fm.removeItem(at: local)

        let mdata = try Data(contentsOf: unz.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: mdata)
        guard manifest.format_version == 1 else {
            throw ImportError(message: "Unsupported models.zip format_version \(manifest.format_version) (expected 1)")
        }

        for n in names {
            let t0 = Date()
            log("compiling \(n)…")
            let compiled = try await MLModel.compileModel(at: unz.appendingPathComponent("\(n).mlpackage"))
            let dest = compiledURL(n)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: compiled, to: dest)   // compileModel output is temporary: move it out
            log(String(format: "compiled %@ in %.1f s", n, Date().timeIntervalSince(t0)))
        }
        for f in ["emap.bin", "manifest.json"] {
            let dest = dir.appendingPathComponent(f)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: unz.appendingPathComponent(f), to: dest)
        }
        log("import complete")
    }
}
