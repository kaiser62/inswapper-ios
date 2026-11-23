import SwiftUI

/// CI screenshot stand-ins for the export screens (`-uiPreview export-sheet|export-running|export-paused|export-done|export-failed`). Placeholder data only.
struct ExportPreview: View {
    let kind: String
    @StateObject private var session = ExportSession()

    var body: some View {
        Group {
            if kind == "export-sheet" {
                ExportSheet(plan: ExportEngine.Plan(width: 1280, height: 720, frames: 1800, alreadyRendered: 450, diskNeeded: 1_200_000_000),
                            duration: 60, swapsPerSecond: 15, strength: 100, swapperName: "8-bit", freeBytes: 24_000_000_000, onStart: {})
            } else {
                ExportProgressView(session: session, onClose: {})
                    .onAppear {
                        switch kind {
                        case "export-running": session.debugSet(.running, phase: .rendering, done: 612, total: 1800, secondsLeft: 540, thermal: .serious)
                        case "export-paused": session.debugSet(.running, phase: .encoding, done: 900, total: 1800, secondsLeft: 12, thermal: .nominal, paused: true)
                        case "export-done": session.debugSet(.done(URL(fileURLWithPath: "/tmp/InSwap-20261123-141500.mp4")), phase: .encoding, done: 1800, total: 1800, secondsLeft: nil, thermal: .nominal)
                        default: session.debugSet(.failed("Not enough free space: need about 1200 MB, have 300 MB."), phase: .rendering, done: 0, total: 1800, secondsLeft: nil, thermal: .nominal)
                        }
                    }
            }
        }
    }
}
