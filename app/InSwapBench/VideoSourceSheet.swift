import PhotosUI
import SwiftUI

/// Where the video comes from: Photos, Files, or the saved library (which also holds the link download).
struct VideoSourceSheet: View {
    @Binding var photosItem: PhotosPickerItem?
    let onFiles: () -> Void
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                PhotosPicker(selection: $photosItem, matching: .videos, preferredItemEncoding: .current) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Button("Files", systemImage: "folder", action: onFiles)
                Button("Saved videos and links", systemImage: "play.square.stack", action: onSaved)
            }
            .navigationTitle("Choose video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: photosItem) { _, new in if new != nil { dismiss() } }
        }
        .presentationDetents([.medium])
    }
}
