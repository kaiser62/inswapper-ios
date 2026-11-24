import SwiftUI

/// Models, diagnostics and app info. Copying the log is two taps away (Settings, then the button).
struct SettingsView: View {
    @ObservedObject private var log = AppLog.shared
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ContentView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Models and benchmark")
                            Text(ModelStore.isInstalled ? "Installed" : "Import needed").font(.footnote).foregroundStyle(ModelStore.isInstalled ? Theme.good : Theme.warn)
                        }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Import models.zip here the first time. The benchmark measures how fast this phone swaps a face.")
                }
                .listRowBackground(Theme.surface)
                Section("Diagnostics") {
                    NavigationLink("Logs") { LogsView() }
                    Button(copied ? "Copied" : "Copy logs", systemImage: "doc.on.doc", action: copyLogs)
                }
                .listRowBackground(Theme.surface)
                Section("About") {
                    LabeledContent("Build", value: PlayerVM.build)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
        }
    }

    private func copyLogs() {
        UIPasteboard.general.string = log.text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
