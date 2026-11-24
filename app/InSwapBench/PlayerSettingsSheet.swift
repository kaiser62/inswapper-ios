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
                Section {
                    if hasFast {
                        Toggle("Fast 8-bit swapper", isOn: $fastSwapper)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Strength")
                        Segmented(options: [("100", 100), ("150", 150), ("200", 200), ("300", 300)], selection: $strength)
                    }
                    Toggle("Live preview where not rendered yet", isOn: $combo)
                } header: {
                    Text("Quality")
                } footer: {
                    Text("The 8-bit swapper is about 2.4x faster. Strength above 100 adds swap passes in Render ahead: slower, with a stronger likeness. \(costText)")
                }
                .listRowBackground(Theme.surface)
                Section("Storage") {
                    LabeledContent("Render cache", value: cacheText)
                    Button("Clear cache", role: .destructive, action: onClearCache)
                }
                .listRowBackground(Theme.surface)
                if !diagnostics.isEmpty {
                    Section("Diagnostics") {
                        DisclosureGroup("Details") {
                            Text(diagnostics).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("Copy diagnostics", action: onCopyDiagnostics)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Player settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }
}
