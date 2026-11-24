import SwiftUI

/// Faces and saved videos in one place.
struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable { case faces = "Faces", videos = "Videos", exports = "Exports"; var id: String { rawValue } }
    @EnvironmentObject private var router: AppRouter
    @State private var section: Section

    init(initial: Section = .faces) { _section = State(initialValue: initial) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Segmented(options: Section.allCases.map { ($0.rawValue, $0) }, selection: $section)
                    .padding(.horizontal, Theme.pad).padding(.bottom, Theme.gap)
                switch section {
                case .faces: FacesView()
                case .videos: VideoLibrarySheet(onPick: open, embedded: true).scrollContentBackground(.hidden)
                case .exports: TakesView()
                }
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func open(_ e: VideoLibrary.Entry) { router.pendingVideo = e; router.tab = .player }
}
