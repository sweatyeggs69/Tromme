import SwiftUI

struct QueueActionPill<Label: View>: View {
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(isActive ? .white : .white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(isActive ? 0.24 : 0.10))
                }
        }
        .buttonStyle(.plain)
    }
}

extension QueueActionPill where Label == AnyView {
    init(systemImage: String, isActive: Bool, action: @escaping () -> Void) {
        self.init(isActive: isActive, action: action) {
            AnyView(Image(systemName: systemImage).contentTransition(.symbolEffect(.replace)))
        }
    }
}
