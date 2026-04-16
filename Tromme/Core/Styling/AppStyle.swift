import SwiftUI

enum AppStyle {
    enum Colors {
        static let tint = Color(red: 0, green: 0.6, blue: 0.6)
    }

    enum Spacing {
        static let sectionGap: CGFloat = 12
        static let cardGap: CGFloat = 16
        static let pageHorizontal: CGFloat = 20
        static let nowPlayingHorizontal: CGFloat = 32
        static let listItemGap: CGFloat = 0
    }

    enum Radius {
        static let card: CGFloat = 8
        static let avatar: CGFloat = 60
    }

    enum TrackGrid {
        static let artworkSize: CGFloat = 46
        static let rowSpacing: CGFloat = 8
        static let itemWidth: CGFloat = 325
    }

    enum AlbumLayout {
        static let gridVerticalPadding: CGFloat = 8

        static let listArtworkSize: CGFloat = 64
        static let listArtworkCornerRadius: CGFloat = 8
        static let listTextSpacing: CGFloat = 2
        static let listRowVerticalPadding: CGFloat = 1
        static let listRowInsets = EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
    }

    enum ArtistDetailAlbumGrid {
        static let itemSpacing: CGFloat = 20
        static let rowSpacing: CGFloat = 20
        static let itemContentSpacing: CGFloat = 4
        static let artworkCornerRadius: CGFloat = 8
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
