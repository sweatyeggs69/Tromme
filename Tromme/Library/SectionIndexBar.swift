import SwiftUI

/// Vertical A–Z index for ScrollView-based layouts, where the stock List section index isn't available.
struct SectionIndexBar: View {
    let titles: [String]
    let onSelect: (String) -> Void

    private static let rowHeight: CGFloat = 14

    @State private var lastSelected: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                    .frame(height: Self.rowHeight)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in select(at: value.location.y) }
                .onEnded { _ in lastSelected = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Section index")
        .accessibilityAdjustableAction { direction in
            let current = lastSelected.flatMap(titles.firstIndex(of:)) ?? (direction == .increment ? -1 : titles.count)
            let next = direction == .increment ? current + 1 : current - 1
            guard titles.indices.contains(next) else { return }
            lastSelected = titles[next]
            onSelect(titles[next])
        }
    }

    private func select(at y: CGFloat) {
        guard !titles.isEmpty else { return }
        let index = min(max(Int((y - 4) / Self.rowHeight), 0), titles.count - 1)
        let title = titles[index]
        guard title != lastSelected else { return }
        lastSelected = title
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect(title)
    }
}

#Preview {
    SectionIndexBar(titles: ["A", "B", "C", "D", "E", "F", "G", "#"]) { _ in }
        .tint(.blue)
}
