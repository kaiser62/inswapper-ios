import PhotosUI
import SwiftUI

/// Where the face comes from: a fresh photo or the face library; a picked photo can be saved to the library.
struct FaceSourceSheet: View {
    @Binding var photoItem: PhotosPickerItem?
    let canSave: Bool
    let onLibrary: () -> Void
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose a photo", systemImage: "person.crop.square")
                }
                Button("Face library", systemImage: "person.2", action: onLibrary)
                if canSave {
                    Button("Save this face to the library", systemImage: "square.and.arrow.down") { onSave(); dismiss() }
                }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Choose face")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: photoItem) { _, new in if new != nil { dismiss() } }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.background)
    }
}
