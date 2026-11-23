import SwiftUI

/// Faces and saved videos in one place.
struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable { case faces = "Faces", videos = "Videos"; var id: String { rawValue } }
    @EnvironmentObject private var router: AppRouter
    @State private var section: Section

    init(initial: Section = .faces) { _section = State(initialValue: initial) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Library", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.pad).padding(.bottom, Theme.gap)
                switch section {
                case .faces: FacesView()
                case .videos: VideoLibrarySheet(onPick: open, embedded: true).scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func open(_ e: VideoLibrary.Entry) { router.pendingVideo = e; router.tab = .player }
}
