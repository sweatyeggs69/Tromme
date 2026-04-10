import SwiftUI

enum AppStyle {
    enum Colors {
        static let tint: Color = .orange
    }

    enum Spacing {
        static let sectionGap: CGFloat = 12
        static let cardGap: CGFloat = 16
        static let pageHorizontal: CGFloat = 20
        static let listItemGap: CGFloat = 0
    }

    enum Radius {
        static let card: CGFloat = 10
        static let avatar: CGFloat = 60
    }

    enum Typography {
        static let sectionTitle: Font = .title2.bold()
        static let itemTitle: Font = .subheadline.weight(.medium)
        static let itemSubtitle: Font = .caption
    }
}

extension View {
    func appSectionTitleStyle() -> some View {
        self
            .font(AppStyle.Typography.sectionTitle)
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
    }

    func appItemTitleStyle() -> some View {
        self
            .font(AppStyle.Typography.itemTitle)
            .lineLimit(1)
    }

    func appItemSubtitleStyle() -> some View {
        self
            .font(AppStyle.Typography.itemSubtitle)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    func appGlobalListStyle() -> some View {
        self
            .listStyle(.plain)
            .listRowSpacing(AppStyle.Spacing.listItemGap)
    }

    func appPlainRowItemStyle() -> some View {
        self
    }
}
