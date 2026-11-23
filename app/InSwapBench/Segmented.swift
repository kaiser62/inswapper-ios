import SwiftUI

/// Inset segmented control in the VisoSwap style: dark track, selected segment filled with the active teal.
struct Segmented<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { withAnimation(Theme.spring) { selection = options[i].value } } label: {
                    Text(options[i].label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Theme.accent : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: Theme.hit - 8)
                        .background(on ? Theme.active : .clear, in: .rect(cornerRadius: Theme.radiusChip + 2))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.background, in: .rect(cornerRadius: Theme.radiusSmall))
    }
}
