import SwiftUI

/// Label for a source button: a leading thumbnail or symbol, a title and an optional detail line.
struct SourceChip: View {
    let title: String
    var detail: String?
    var systemImage: String
    var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: Theme.gap) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(Circle())
            } else {
                Image(systemName: systemImage).foregroundStyle(Theme.accent).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.bold()).lineLimit(1)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }
}
