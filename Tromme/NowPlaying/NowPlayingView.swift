import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct NowPlayingView: View {
    // MARK: - Environment

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    let startPanel: NowPlayingStartPanel
    var onNavigate: ((PlexMetadata) -> Void)?

    // MARK: - State

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyricsService = LyricsService()
    @State private var isVisible = false
    @State private var appliedInitialLandscapeLyrics = false
    @State private var addToPlaylistRequest: AddToPlaylistRequest?
    @State private var isRating = false
    // Caches the last valid geometry to recover from the transient invalid
    // dimensions GeometryReader reports during CarPlay + app-switch transitions.
    @State private var geoSize: CGSize = {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return scene.screen.bounds.size
        }
        return CGSize(width: 390, height: 844)
    }()

    init(startPanel: NowPlayingStartPanel = .none, onNavigate: ((PlexMetadata) -> Void)? = nil) {
        self.startPanel = startPanel
        self.onNavigate = onNavigate
        _showLyrics = State(initialValue: startPanel == .lyrics)
        _showQueue = State(initialValue: startPanel == .queue)
    }

    // MARK: - Layout Constants (see AppStyle.NowPlaying)

    private var bottomActionsLeadingButtonPadding: CGFloat { AppStyle.NowPlaying.bottomActionsLeadingPadding }
    private var bottomActionsTrailingButtonPadding: CGFloat { AppStyle.NowPlaying.bottomActionsTrailingPadding }
    private var actionIconActiveOpacity: Double { AppStyle.NowPlaying.actionIconActiveOpacity }
    private var actionIconInactiveOpacity: Double { AppStyle.NowPlaying.actionIconInactiveOpacity }
    private var actionBackgroundOpacity: Double { AppStyle.NowPlaying.actionBackgroundOpacity }
    private var actionBackgroundActiveOpacity: Double { AppStyle.NowPlaying.actionBackgroundActiveOpacity }
    private var controlTintOpacity: Double { AppStyle.NowPlaying.controlTintOpacity }
    private var bottomActionIconSize: CGFloat { AppStyle.NowPlaying.bottomActionIconSize }
    private var iPadBottomActionsExtraPadding: CGFloat { AppStyle.NowPlaying.iPadBottomActionsExtraPadding }
    private var iPadLandscapeBottomActionsExtraPadding: CGFloat { AppStyle.NowPlaying.iPadLandscapeBottomActionsExtraPadding }
    private var portraitArtworkBottomPadding: CGFloat { AppStyle.NowPlaying.portraitArtworkBottomPadding }
    private var portraitTrackInfoBottomPadding: CGFloat { AppStyle.NowPlaying.portraitTrackInfoBottomPadding }
    private var portraitBottomControlsHeightFraction: CGFloat { AppStyle.NowPlaying.portraitBottomControlsHeightFraction }
    private var landscapeBottomControlsHeightFraction: CGFloat { AppStyle.NowPlaying.landscapeBottomControlsHeightFraction }
    private var bottomActionsTopPadding: CGFloat { AppStyle.NowPlaying.bottomActionsTopPadding }
    private var bottomScreenPaddingWithSafeArea: CGFloat { AppStyle.NowPlaying.bottomScreenPaddingWithSafeArea }
    private var bottomScreenPaddingWithoutSafeArea: CGFloat { AppStyle.NowPlaying.bottomScreenPaddingWithoutSafeArea }

    // MARK: - Computed Properties

    private var isCompact: Bool { showLyrics || showQueue }

    private var isFavorited: Bool {
        (player.currentTrack?.userRating ?? 0) >= 10
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width > 100 ? geo.size.width : geoSize.width
            let height = geo.size.height > 100 ? geo.size.height : geoSize.height
            let isPortrait = height >= width
            let baseArtworkWidth = width - 48.0
            let baseArtworkHeight = height * 0.5
            let artworkSize = max(min(baseArtworkWidth, baseArtworkHeight), 2.0)
            let isPadLandscape = UIDevice.current.userInterfaceIdiom == .pad && width > height
            let isPadPortrait = UIDevice.current.userInterfaceIdiom == .pad && height > width
            let controlsContainerWidth = artworkSize
            let controlsHorizontalPadding: CGFloat = 0
            let bottomControlsHeightFraction = isPortrait
                ? portraitBottomControlsHeightFraction
                : landscapeBottomControlsHeightFraction
            let bottomControlsHeight = height * bottomControlsHeightFraction
            let landscapeOuterHorizontalPadding: CGFloat = 24
            let landscapeColumnSpacing: CGFloat = 24
            let landscapeContentWidth = max(0.0, width - (landscapeOuterHorizontalPadding * 2))
            let bottomScreenPadding = geo.safeAreaInsets.bottom > 0
                ? bottomScreenPaddingWithSafeArea
                : bottomScreenPaddingWithoutSafeArea
            let landscapeBottomInsetPadding = bottomScreenPadding
            let landscapeHandleHeight: CGFloat = 21
            let landscapeBottomActionsHeight: CGFloat = bottomActionIconSize + iPadLandscapeBottomActionsExtraPadding
            let landscapeMainHeight = max(
                0.0,
                height - landscapeHandleHeight - landscapeBottomActionsHeight - landscapeBottomInsetPadding
            )
            let landscapeArtworkControlsSpacing: CGFloat = 20
            let landscapePlayerControlsHeight = landscapeMainHeight * portraitBottomControlsHeightFraction
            let landscapeArtworkAreaHeight = max(96.0, landscapeMainHeight - landscapePlayerControlsHeight - landscapeArtworkControlsSpacing)
            let landscapeArtworkSize = max(96.0, landscapeArtworkAreaHeight - 16)
            let landscapeLeftWidth = max(96.0, landscapeArtworkAreaHeight)
            let landscapeRightWidth = max(0.0, landscapeContentWidth - landscapeLeftWidth - landscapeColumnSpacing)

            let _ = applyInitialLandscapeLyrics(isPadLandscape: isPadLandscape)

            if isPadLandscape {
                VStack(spacing: 0) {
                    dragHandle
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    HStack(alignment: .top, spacing: landscapeColumnSpacing) {
                        VStack(spacing: landscapeArtworkControlsSpacing) {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)

                                ArtworkView(
                                    thumbPath: (player.currentTrack?.parentThumb ?? player.currentTrack?.thumb),
                                    size: landscapeArtworkSize,
                                    cornerRadius: AppStyle.Radius.card
                                )
                                .shadow(color: .black.opacity(player.isPlaying ? 0.35 : 0.12), radius: 20, x: 0, y: 10)
                                .shadow(color: .black.opacity(player.isPlaying ? 0.15 : 0.05), radius: 6, x: 0, y: 3)
                                .scaleEffect(player.isPlaying ? 1.0 : 0.85)
                                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

                                Spacer(minLength: 0)
                            }
                            .frame(height: landscapeArtworkAreaHeight)

                            trackAndPlaybackControls(
                                horizontalPadding: 0,
                                isPadPortrait: false,
                                trackInfoBottomPadding: 10
                            )
                            .frame(width: landscapeArtworkSize)
                            .frame(height: landscapePlayerControlsHeight)
                        }
                        .frame(width: landscapeLeftWidth)

                        if showLyrics || showQueue {
                            lyricsQueueContent
                                .frame(width: landscapeRightWidth)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .padding(.top, 8)
                                .transition(.opacity)
                        } else {
                            Spacer(minLength: 0)
                                .frame(width: landscapeRightWidth)
                        }
                    }
                    .frame(height: landscapeMainHeight)
                    .padding(.horizontal, landscapeOuterHorizontalPadding)

                    landscapeBottomActionsRow
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .padding(.horizontal, landscapeOuterHorizontalPadding)
                        .padding(.bottom, iPadLandscapeBottomActionsExtraPadding)
                }
                .padding(.bottom, landscapeBottomInsetPadding)
                .animation(.easeInOut(duration: 0.25), value: showLyrics)
                .animation(.easeInOut(duration: 0.25), value: showQueue)
            } else {
                VStack(spacing: 0) {
                    dragHandle
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    Spacer(minLength: 16)

                    // Reserves the full-size artwork's resting spot; the real artwork
                    // is rendered once, floating, and positioned over this spot (or
                    // the small one in trackInfo) via the anchor overlay below.
                    ZStack {
                        Color.clear
                            .frame(width: artworkSize, height: artworkSize)
                            .anchorPreference(key: ArtworkSlotAnchorsKey.self, value: .bounds) { [.full: $0] }

                        lyricsQueueContent
                            .frame(width: controlsContainerWidth)
                            .opacity(isCompact ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, portraitArtworkBottomPadding)
                    .zIndex(1)

                    // Bottom controls — pinned to bottom
                    VStack(spacing: 0) {
                        trackAndPlaybackControls(
                            horizontalPadding: controlsHorizontalPadding,
                            isPadPortrait: isPadPortrait,
                            trackInfoBottomPadding: portraitTrackInfoBottomPadding,
                            showsCompactArtwork: true
                        )
                        .frame(maxHeight: .infinity)
                        bottomActions
                            .padding(.horizontal, controlsHorizontalPadding)
                            .padding(.top, bottomActionsTopPadding)

                    }
                    .frame(maxWidth: controlsContainerWidth)
                    .frame(maxWidth: .infinity)
                    .frame(height: bottomControlsHeight)
                    .padding(.bottom, bottomScreenPadding)
                }
                // Shadow lives behind the content so it never draws over the track and artist text.
                // The shadow box follows the artwork's slot and fades out/in during the move, so its
                // black box never shows as a square while the artwork animates to the compact slot.
                .backgroundPreferenceValue(ArtworkSlotAnchorsKey.self) { anchors in
                    GeometryReader { proxy in
                        if let fullAnchor = anchors[.full] {
                            let rect: CGRect = {
                                if isCompact, let compactAnchor = anchors[.compact] {
                                    return proxy[compactAnchor]
                                }
                                return proxy[fullAnchor]
                            }()
                            RoundedRectangle(cornerRadius: isCompact ? 4 : 6)
                                .fill(Color.black)
                                .frame(width: rect.width, height: rect.height)
                                .shadow(color: .black.opacity(isCompact ? 0 : (player.isPlaying ? 0.38 : 0.14)), radius: isCompact ? 0 : 36, x: 0, y: isCompact ? 0 : 18)
                                .shadow(color: .black.opacity(isCompact ? 0 : (player.isPlaying ? 0.15 : 0.05)), radius: isCompact ? 0 : 8, x: 0, y: isCompact ? 0 : 4)
                                .scaleEffect(isCompact ? 1.0 : (player.isPlaying ? 1.0 : 0.85))
                                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                                .opacity(isCompact ? 0 : 1)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .overlayPreferenceValue(ArtworkSlotAnchorsKey.self) { anchors in
                    GeometryReader { proxy in
                        if let fullAnchor = anchors[.full] {
                            let fullRect = proxy[fullAnchor]
                            let targetRect: CGRect = {
                                if isCompact, let compactAnchor = anchors[.compact] {
                                    return proxy[compactAnchor]
                                }
                                return fullRect
                            }()

                            ArtworkView(
                                thumbPath: (player.currentTrack?.parentThumb ?? player.currentTrack?.thumb),
                                size: targetRect.width,
                                cornerRadius: isCompact ? 4 : 6,
                                // Keep requesting the full-size image in the compact slot too, so
                                // shrinking never swaps to a different size that may not be loaded yet.
                                minimumTranscodePx: ArtworkView.maxTranscodePx
                            )
                            .scaleEffect(isCompact ? 1.0 : (player.isPlaying ? 1.0 : 0.85))
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                            .position(x: targetRect.midX, y: targetRect.midY)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            // Tracks valid geometry to recover from the brief invalid dimensions
            // reported during CarPlay + app-switch scene transitions.
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: geo.size, initial: true) { _, size in
                    if size.width > 100 && size.height > 100 {
                        geoSize = size
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { NowPlayingBackground() }
        .overlay(alignment: .topLeading) {
            VolumeHUDSuppressor()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .opacity(0.01)
        }
        .preferredColorScheme(.dark)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 80 {
                        dismiss()
                    }
                }
        )
        .onAppear {
            isVisible = true
            guard let track = player.currentTrack else { return }
            Task {
                await lyricsService.fetch(track: track)
            }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: player.currentTrack?.ratingKey) { _, _ in
            guard isVisible, let track = player.currentTrack else { return }
            Task {
                await lyricsService.fetch(track: track)
            }
        }
        .sheet(item: $addToPlaylistRequest) { request in
            AddToPlaylistSheet(itemRatingKeys: request.itemRatingKeys)
        }
    }

    @ViewBuilder
    private var lyricsQueueContent: some View {
        Group {
            if showLyrics {
                ZStack {
                    if lyricsService.isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white.opacity(0.82))
                            Text("Fetching Lyrics…")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                    } else if lyricsService.hasLyrics {
                        LyricsScrollView(lyricsService: lyricsService)
                            .mask(
                                VStack(spacing: 0) {
                                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                                        .frame(height: 80)
                                    Color.white
                                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                                        .frame(height: 80)
                                }
                            )
                            .transition(.opacity)
                    } else {
                        NowPlayingEmptyState(message: "No Lyrics Available", systemImage: "quote.bubble")
                            .transition(.opacity)
                    }

                }
                .animation(.easeInOut(duration: 0.25), value: lyricsService.isLoading)
                .animation(.easeInOut(duration: 0.25), value: lyricsService.hasLyrics)
            } else if showQueue {
                QueueView(player: player)
                    .mask(
                        VStack(spacing: 0) {
                            Color.white
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 20)
                        }
                    )
            }
        }
    }

    // MARK: - Lifecycle
    // onAppear / onDisappear / onChange are attached in body above.

    // MARK: - Track Info

    private func trackInfo(showsCompactArtwork: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 0) {
            if showsCompactArtwork {
                // Always present so the text block shifts as one unit while the slot's width animates.
                let slotOpen = isCompact
                Color.clear
                    .frame(width: slotOpen ? 44 : 0, height: 44)
                    .anchorPreference(key: ArtworkSlotAnchorsKey.self, value: .bounds) { [.compact: $0] }
                Color.clear.frame(width: slotOpen ? 12 : 0, height: 0)
            }

            VStack(alignment: .leading) {
                MarqueeText(text: player.currentTrack?.title ?? "Not Playing")
                Button {
                    goToArtist()
                } label: {
                    Text(player.currentTrack?.artistDisplayName ?? "")
                        .font(.title3)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)

            HStack(spacing: 10) {
                Button {
                    toggleFavorite()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(actionBackgroundOpacity))
                        Image(systemName: isFavorited ? "star.fill" : "star")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isRating || player.currentTrack == nil)

                Menu {
                    trackContextMenuItems
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(actionBackgroundOpacity))
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Controls Stack

    private func trackAndPlaybackControls(
        horizontalPadding: CGFloat,
        isPadPortrait: Bool,
        trackInfoBottomPadding: CGFloat,
        showsCompactArtwork: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            trackInfo(showsCompactArtwork: showsCompactArtwork)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, trackInfoBottomPadding)

            controlsStack(
                horizontalPadding: horizontalPadding,
                isPadPortrait: isPadPortrait,
                usesEvenSpacing: true
            )
            .frame(maxHeight: .infinity)
        }
    }

    private func controlsStack(
        horizontalPadding: CGFloat,
        bottomPadding: CGFloat = 20,
        isPadPortrait: Bool = false,
        usesEvenSpacing: Bool = false,
        usesCompactSpacing: Bool = false
    ) -> some View {
        let sliderBottomPadding: CGFloat = usesCompactSpacing ? 10 : (isPadPortrait ? 42 : 18)
        let transportBottomPadding: CGFloat = usesCompactSpacing ? 16 : (isPadPortrait ? 64 : 32)
        let volumeBottomPadding: CGFloat = usesCompactSpacing ? 8 : (isPadPortrait ? 38 : (bottomPadding + 6))

        return Group {
            if usesEvenSpacing {
                VStack(spacing: 0) {
                    TimelineSlider(usesOverlayedTimeLabels: true)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 12)

                    Spacer(minLength: 0)

                    transportControls
                        .frame(height: 56)
                        .padding(.horizontal, horizontalPadding)

                    Spacer(minLength: 0)

                    volumeRow(horizontalPadding: horizontalPadding)
                }
            } else {
                VStack(spacing: 0) {
                    TimelineSlider()
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, sliderBottomPadding)
                    transportControls
                        .frame(height: 56)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, transportBottomPadding)
                    volumeRow(horizontalPadding: horizontalPadding)
                        .padding(.bottom, volumeBottomPadding)
                }
            }
        }
    }

    @ViewBuilder
    private func volumeRow(horizontalPadding: CGFloat) -> some View {
        VolumeSlider(isEnabled: !player.isCarPlayConnected)
            .frame(height: 32)
        .padding(.horizontal, horizontalPadding)
    }

    // MARK: - Track Context Menu

    @ViewBuilder
    private var trackContextMenuItems: some View {
        if let track = player.currentTrack {
            if let album = PlexMetadata.albumStub(from: track) {
                Button {
                    onNavigate?(album)
                    dismiss()
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                    Text(track.parentTitle ?? "")
                }
            }
            if PlexMetadata.artistStub(from: track) != nil {
                Button {
                    goToArtist()
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                    Text(track.grandparentTitle ?? track.artistName)
                }
            }
            Button {
                addToPlaylistRequest = AddToPlaylistRequest(itemRatingKeys: [track.ratingKey])
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            if showLyrics {
                Divider()
                Button {
                    Task { await lyricsService.refresh(track: track) }
                } label: {
                    Label("Refresh Lyrics", systemImage: "arrow.clockwise")
                }
                .disabled(lyricsService.isLoading)
                if lyricsService.current != nil {
                    Button {
                        Task { await lyricsService.blockCurrent(track: track) }
                    } label: {
                        Label("Wrong Lyrics", systemImage: "hand.thumbsdown")
                    }
                    .disabled(lyricsService.isLoading)
                }
                if lyricsService.hasBlockedLyrics(track: track) {
                    Button {
                        Task { await lyricsService.unblockAll(track: track) }
                    } label: {
                        Label("Restore Blocked Lyrics", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(lyricsService.isLoading)
                }
            }
        }
    }

    // MARK: - Favorite

    private func toggleFavorite() {
        guard let track = player.currentTrack,
              let server = serverConnection.currentServer else { return }
        let sectionId = serverConnection.currentLibrarySectionId
        let removing = isFavorited
        isRating = true
        Task {
            _ = await player.setFavorited(!removing, for: track, server: server, client: client, sectionId: sectionId)
            isRating = false
        }
    }

    // MARK: - Navigation

    private func goToArtist() {
        guard let track = player.currentTrack,
              let artist = PlexMetadata.artistStub(from: track) else { return }
        onNavigate?(artist)
        dismiss()
    }

    // MARK: - Lyrics Refresh Button

    private var lyricsRefreshButton: some View {
        Button {
            guard let track = player.currentTrack else { return }
            Task { await lyricsService.refresh(track: track) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(actionIconInactiveOpacity))
                .frame(width: 30, height: 30)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: lyricsService.isLoading)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(lyricsService.isLoading)
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white.opacity(0.3))
            .frame(width: 36, height: 5)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: player.isPlaying ? 52 : 46))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: player.isPlaying)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            Spacer()
        }
    }

    // MARK: - Bottom Actions

    private var landscapeBottomActionsRow: some View {
        HStack {
            AirPlayButton(
                tintOpacity: CGFloat(controlTintOpacity),
                activeTintOpacity: CGFloat(actionIconActiveOpacity)
            )
            .frame(width: bottomActionIconSize, height: bottomActionIconSize)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    toggleLyricsPanel()
                } label: {
                    panelToggleIcon(systemName: "quote.bubble", isActive: showLyrics)
                }
                .buttonStyle(.plain)

                Button {
                    toggleQueuePanel()
                } label: {
                    panelToggleIcon(systemName: "list.bullet", isActive: showQueue)
                        .overlay(alignment: .topTrailing) {
                            if player.isShuffled && !showQueue { shuffleBadge }
                        }
                }
                .buttonStyle(.plain)
            }
            .font(.title3.weight(.semibold))
        }
    }

    private var bottomActions: some View {
        HStack {
            Button {
                toggleLyricsPanel()
            } label: {
                panelToggleIcon(systemName: "quote.bubble", isActive: showLyrics)
            }
            .buttonStyle(.plain)
            .padding(.leading, bottomActionsLeadingButtonPadding)

            Spacer()

            AirPlayButton(
                tintOpacity: CGFloat(controlTintOpacity),
                activeTintOpacity: CGFloat(actionIconActiveOpacity)
            )
                .frame(width: bottomActionIconSize, height: bottomActionIconSize)

            Spacer()

            Button {
                toggleQueuePanel()
            } label: {
                panelToggleIcon(systemName: "list.bullet", isActive: showQueue)
                    .overlay(alignment: .topTrailing) {
                        if player.isShuffled && !showQueue { shuffleBadge }
                    }
            }
            .buttonStyle(.plain)
            .padding(.trailing, bottomActionsTrailingButtonPadding)
        }
        .font(.title3.weight(.semibold))
    }

    @discardableResult
    private func applyInitialLandscapeLyrics(isPadLandscape: Bool) -> Bool {
        if !appliedInitialLandscapeLyrics, startPanel == .none, isPadLandscape {
            Task { @MainActor in
                showQueue = false
                showLyrics = true
                appliedInitialLandscapeLyrics = true
            }
        }
        return true
    }

    private func toggleLyricsPanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showLyrics {
                showLyrics = false
            } else {
                showQueue = false
                showLyrics = true
            }
        }
    }

    private func toggleQueuePanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showQueue {
                showQueue = false
            } else {
                showLyrics = false
                showQueue = true
            }
        }
    }

    private var shuffleBadge: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.25))
            Image(systemName: "shuffle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: 17, height: 17)
        .offset(x: 4, y: -3)
    }

    @ViewBuilder
    private func panelToggleIcon(systemName: String, isActive: Bool) -> some View {
        if isActive {
            ZStack {
                Circle()
                    .fill(.white.opacity(actionBackgroundActiveOpacity))
                Image(systemName: systemName)
                    .foregroundStyle(.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: bottomActionIconSize, height: bottomActionIconSize)
        } else {
            Image(systemName: systemName)
                .foregroundStyle(.white.opacity(actionIconInactiveOpacity))
                .frame(width: bottomActionIconSize, height: bottomActionIconSize)
        }
    }
}
