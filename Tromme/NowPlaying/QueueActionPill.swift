import SwiftUI

struct QueueActionPill: View {
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isActive ? .white : .white.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(isActive ? 0.24 : 0.10))
                }
        }
        .buttonStyle(.plain)
    }
}
