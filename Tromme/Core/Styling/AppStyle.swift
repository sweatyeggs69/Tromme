import SwiftUI

enum AppStyle {
    enum Colors {
        static let defaultTint = Color(red: 1.0, green: 0.4, blue: 0.0)
    }

    enum Spacing {
        static let sectionGap: CGFloat = 12
        static let cardGap: CGFloat = 16
        static let pageHorizontal: CGFloat = 20
        static let nowPlayingHorizontal: CGFloat = 0
        static let listItemGap: CGFloat = 0
        static let sectionIndexInset: CGFloat = 8
    }

    enum Radius {
        static let card: CGFloat = 8
        static let avatar: CGFloat = 60
        static let appIcon: CGFloat = 14
    }

    enum Artwork {
        static let header: CGFloat = 300
        static func portraitHeader(forWidth width: CGFloat) -> CGFloat {
            max(width - Spacing.pageHorizontal * 2, 1)
        }
        static let card: CGFloat = 170
        static let rowThumbnail: CGFloat = 44
        static let emptyStateIcon: CGFloat = 40
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

    // MARK: - Track list rows (Songs, Favorites, Playlists)

    enum TrackList {
        static let artworkSize: CGFloat = 42
        static let browseArtworkSize: CGFloat = 48
        static let artworkCornerRadius: CGFloat = 4
        static let rowInsets = EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
        static let rowSpacing: CGFloat = 2
    }

    // MARK: - Mini Player

    enum MiniPlayer {
        static let artworkSize: CGFloat = 36
        static let artworkSizeInline: CGFloat = 30
        static let artworkCornerRadius: CGFloat = 6
        static let controlSize: CGFloat = 44
        static let playPauseSizePad: CGFloat = 50
        static let secondaryControlSize: CGFloat = 36
        static let leadingPadding: CGFloat = 16
        static let trailingPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 8
        static let spacing: CGFloat = 12
        static let spacingCompact: CGFloat = 8
    }

    // MARK: - Now Playing full-screen view

    enum NowPlaying {
        static let bottomActionsLeadingPadding: CGFloat = 48
        static let bottomActionsTrailingPadding: CGFloat = 48
        static let actionIconActiveOpacity: Double = 0.82
        static let actionIconInactiveOpacity: Double = 0.45
        static let actionBackgroundOpacity: Double = 0.12
        static let actionBackgroundActiveOpacity: Double = 0.4
        static let controlTintOpacity: Double = 0.45
        static let bottomActionIconSize: CGFloat = 42
        static let iPadBottomActionsExtraPadding: CGFloat = 12
        static let portraitTrackInfoBottomPadding: CGFloat = 6
        static let portraitBottomControlsHeightFraction: CGFloat = 0.41
        static let bottomActionsTopPadding: CGFloat = 10
        static let bottomScreenPaddingWithSafeArea: CGFloat = 4
        static let bottomScreenPaddingWithoutSafeArea: CGFloat = 8
    }
}

// MARK: - Color contrast

extension Color {
    func isLightColor(in colorScheme: ColorScheme? = nil) -> Bool {
        var uiColor = UIColor(self)
        if let colorScheme {
            let trait = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
            uiColor = uiColor.resolvedColor(with: trait)
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? (component / 12.92) : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance =
            (0.2126 * linearized(red)) +
            (0.7152 * linearized(green)) +
            (0.0722 * linearized(blue))

        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        let contrastDelta = abs(blackContrast - whiteContrast)

        if contrastDelta < 0.35 {
            return luminance > 0.45
        }
        return blackContrast >= whiteContrast
    }

    var contrastForeground: Color { isLightColor() ? .black : .white }

    var contrastControlForeground: Color { isLightColor() ? .white : .black }

    var contrastControlBackground: Color { isLightColor() ? Color.black.opacity(0.75) : Color.white.opacity(0.82) }

    var contrastCircleBackground: Color { isLightColor() ? Color.black.opacity(0.12) : Color.white.opacity(0.15) }

    var contrastControlShadow: Color { isLightColor() ? Color.black.opacity(0.22) : Color.white.opacity(0.18) }
}

extension View {
    func artworkBorder(cornerRadius: CGFloat = AppStyle.Radius.card) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    func headerArtworkStyle() -> some View {
        artworkBorder()
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

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
