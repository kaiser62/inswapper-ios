import SwiftUI

/// Everything that is not needed during playback: quality, cache and diagnostics.
struct PlayerSettingsSheet: View {
    @Binding var fastSwapper: Bool
    @Binding var strength: Int
    @Binding var combo: Bool
    let hasFast: Bool
    let costText: String
    let cacheText: String
    let diagnostics: String
    let onClearCache: () -> Void
    let onCopyDiagnostics: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Quality") {
                    if hasFast {
                        Toggle("Fast 8-bit swapper", isOn: $fastSwapper)
                    }
                    Picker("Strength", selection: $strength) {
                        Text("100").tag(100); Text("150").tag(150); Text("200").tag(200); Text("300").tag(300)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Live preview where not rendered yet", isOn: $combo)
                } footer: {
                    Text("The 8-bit swapper is about 2.4x faster. Strength above 100 adds swap passes in Render ahead: slower, with a stronger likeness. \(costText)")
                }
                Section("Storage") {
                    LabeledContent("Render cache", value: cacheText)
                    Button("Clear cache", role: .destructive, action: onClearCache)
                }
                if !diagnostics.isEmpty {
                    Section("Diagnostics") {
                        DisclosureGroup("Details") {
                            Text(diagnostics).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("Copy diagnostics", action: onCopyDiagnostics)
                    }
                }
            }
            .navigationTitle("Player settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
