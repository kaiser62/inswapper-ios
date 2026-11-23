import SwiftUI
import UniformTypeIdentifiers

@main
struct InSwapBenchApp: App {
    init() { AppLog.log("launch build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") · \(ProcessInfo.processInfo.operatingSystemVersionString) · thermal \(ProcessInfo.processInfo.thermalState.rawValue)", "app") }
    var body: some Scene {
        WindowGroup {
            TabView {
                PhotoView().tabItem { Label("Photo", systemImage: "face.smiling") }
                PlayerView().tabItem { Label("Player", systemImage: "play.rectangle") }
                ContentView().tabItem { Label("Models & Bench", systemImage: "gauge") }
                LogsView().tabItem { Label("Logs", systemImage: "doc.plaintext") }
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
                HStack {
                    Button("Import models.zip") { picking = true }
                        .buttonStyle(.borderedProminent).disabled(vm.busy)
                    Button("Run benchmark") { vm.runBench() }
                        .buttonStyle(.bordered).disabled(vm.busy || !vm.installed)
                }
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
