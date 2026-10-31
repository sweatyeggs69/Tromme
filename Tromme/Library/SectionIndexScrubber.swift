import SwiftUI

private struct SectionIndexScrubber: ViewModifier {
    let titles: [String]
    @State private var activeTitle: String?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .contentMargins(.trailing, AppStyle.Spacing.sectionIndexInset + 12, for: .scrollContent)
                .overlay(alignment: .trailing) {
                    if !titles.isEmpty {
                        SectionIndexBar(titles: titles, activeTitle: $activeTitle) { title in
                            proxy.scrollTo(title, anchor: .top)
                        }
                    }
                }
                .overlay { SectionIndexPopup(title: activeTitle) }
        }
    }
}

extension View {
    func sectionIndexScrubber(titles: [String]) -> some View {
        modifier(SectionIndexScrubber(titles: titles))
    }
}
