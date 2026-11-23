import SwiftUI
import UniformTypeIdentifiers

@main
struct InSwapBenchApp: App {
    init() { AppLog.log("launch build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") · \(ProcessInfo.processInfo.operatingSystemVersionString) · thermal \(ProcessInfo.processInfo.thermalState.rawValue)", "app") }
    /// `-uiPreview <screen>` (CI screenshots, see .github/workflows/screenshots.yml) opens that tab at launch. Screens: photo faces player bench logs.
    @State private var tab: String = {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-uiPreview"), i + 1 < a.count { return a[i + 1] }
        return "player"
    }()
    var body: some Scene {
        WindowGroup {
            if tab.hasPrefix("export-") { ExportPreview(kind: tab).preferredColorScheme(.dark) } else if tab.hasPrefix("player-") { PlayerPreview(kind: tab).preferredColorScheme(.dark) } else {
            TabView(selection: $tab) {
                PhotoView().tabItem { Label("Photo", systemImage: "face.smiling") }.tag("photo")
                FacesView().tabItem { Label("Faces", systemImage: "person.2.crop.square.stack") }.tag("faces")
                PlayerView().tabItem { Label("Player", systemImage: "play.rectangle") }.tag("player")
                ContentView().tabItem { Label("Models & Bench", systemImage: "gauge") }.tag("bench")
                LogsView().tabItem { Label("Logs", systemImage: "doc.plaintext") }.tag("logs")
            }
            .preferredColorScheme(.dark).tint(Theme.accent)
            }
        }
    }
}

@MainActor
final class VM: ObservableObject {
    @Published var output = ""
    @Published var busy = false
    @Published var installed = ModelStore.isInstalled

    func append(_ s: String) { output += s + "\n"; AppLog.log(s, "bench") }

    func importPicked(_ url: URL) {
        busy = true
        output = ""
        Task {
            do {
                try await ModelStore.importZip(url) { msg in Task { @MainActor in self.append(msg) } }
            } catch {
                append("IMPORT FAILED: \(error.localizedDescription)")
            }
            installed = ModelStore.isInstalled
            busy = false
        }
    }

    func run(_ job: @escaping (@escaping (String) -> Void) async -> Void) {
        busy = true
        output = ""
        Task.detached(priority: .userInitiated) {
            await job { msg in Task { @MainActor in self.append(msg) } }
            await MainActor.run { self.busy = false }
        }
    }

    func runBench() {
        busy = true
        output = ""
        Task.detached(priority: .userInitiated) {
            await Bench.run { msg in Task { @MainActor in self.append(msg) } }
            await MainActor.run { self.busy = false }
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = VM()
    @State private var picking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(vm.installed ? "Models installed" : "No models yet: import models.zip")
                    .font(.subheadline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    Button("Import models.zip") { picking = true }
                        .buttonStyle(.borderedProminent).disabled(vm.busy)
                    Button("Run benchmark") { vm.runBench() }
                        .buttonStyle(.bordered).disabled(vm.busy || !vm.installed)
                    Button("Compare 8-bit swapper") { vm.run { log in await Bench.swapperCompare(log: log) } }
                        .buttonStyle(.bordered).disabled(vm.busy || !vm.installed)
                    Button("5 min FP16") { vm.run { log in await Bench.sustainedSwapper("swapper", seconds: 300, log: log) } }
                        .buttonStyle(.bordered).disabled(vm.busy || !vm.installed)
                    Button("5 min 8-bit") { vm.run { log in await Bench.sustainedSwapper("swapper_pal8", seconds: 300, log: log) } }
                        .buttonStyle(.bordered).disabled(vm.busy || !vm.installed)
                }
                Text("8-bit experiment: import swapper_pal8.zip with the same button. Let the phone cool for a few minutes between the two 5-minute runs.").font(.caption).foregroundStyle(.secondary)
                Button("Copy results") { UIPasteboard.general.string = vm.output }
                    .buttonStyle(.bordered)
                ScrollView {
                    Text(vm.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("InSwapBench")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
            if case let .success(url) = result { vm.importPicked(url) }
        }
    }
}
