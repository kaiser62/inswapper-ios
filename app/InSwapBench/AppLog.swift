import Foundation
import SwiftUI

/// App-wide log (ring buffer, also appended to a file so a crash/relaunch still leaves the previous session's lines).
final class AppLog: ObservableObject, @unchecked Sendable {
    static let shared = AppLog()
    @Published private(set) var text = ""
    private var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 3000
    private let file: URL
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("applog.txt")
        if let old = try? String(contentsOf: file, encoding: .utf8), !old.isEmpty {
            lines = Array(old.split(separator: "\n", omittingEmptySubsequences: true).suffix(400).map(String.init))
            lines.append("---- previous session above ----")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        text = lines.joined(separator: "\n")
    }

    static func log(_ s: String, _ tag: String = "app") { shared.add("[\(tag)] \(s)") }

    func add(_ s: String) {
        lock.lock()
        let line = "\(fmt.string(from: Date())) \(s)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        if let h = try? FileHandle(forWritingTo: file) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((line + "\n").utf8)); try? h.close() }
        let snapshot = lines.joined(separator: "\n")
        lock.unlock()
        DispatchQueue.main.async { self.text = snapshot }
    }

    func clear() {
        lock.lock(); lines = []; try? "".write(to: file, atomically: true, encoding: .utf8); lock.unlock()
        DispatchQueue.main.async { self.text = "" }
    }
}

struct LogsView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                    Button(copied ? "Copied" : "Copy all") { UIPasteboard.general.string = log.text; copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false } }
                        .buttonStyle(CompactPrimaryButtonStyle())
                    ShareLink(item: log.text) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(CompactSoftButtonStyle())
                    Button("Clear", role: .destructive) { log.clear() }.buttonStyle(CompactSoftButtonStyle())
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Text("\(log.text.split(separator: "\n").count) lines").font(.caption).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(log.text.isEmpty ? "No log lines yet." : log.text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: log.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .padding()
            .background(Theme.background)
            .navigationTitle("Logs")
    }
}
