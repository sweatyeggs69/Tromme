import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingView: View {
    // MARK: - Environment

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    let startPanel: NowPlayingStartPanel
    var onNavigate: ((PlexMetadata) -> Void)?

    // MARK: - State

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyricsService = LyricsService()
    @State private var isVisible = false
    @State private var appliedInitialLandscapeLyrics = false
    @AppStorage("miniLyricsModeEnabled") private var miniLyricsModeEnabled = false

    init(startPanel: NowPlayingStartPanel = .none, onNavigate: ((PlexMetadata) -> Void)? = nil) {
        self.startPanel = startPanel
        self.onNavigate = onNavigate
        _showLyrics = State(initialValue: startPanel == .lyrics)
        _showQueue = State(initialValue: startPanel == .queue)
    }

    // MARK: - Layout Constants

    private let bottomActionsLeadingButtonPadding: CGFloat = 48
    private let bottomActionsTrailingButtonPadding: CGFloat = 48
    private let actionIconActiveOpacity: Double = 0.82
    private let actionIconInactiveOpacity: Double = 0.45
    private let actionBackgroundOpacity: Double = 0.12
    private let actionBackgroundActiveOpacity: Double = 0.2
    private let controlTintOpacity: Double = 0.45
    private let iPadBottomActionsExtraPadding: CGFloat = 12
    private let portraitArtworkBottomPadding: CGFloat = 10
    private let portraitTrackInfoBottomPadding: CGFloat = 18

    // MARK: - Computed Properties

    private var isCompact: Bool { showLyrics || showQueue }

    private var activeMiniLyricText: String? {
        guard miniLyricsModeEnabled, !showLyrics, !showQueue, lyricsService.hasSynced else { return nil }
        let index = lyricsService.currentLineIndex(at: player.currentTime)
        guard lyricsService.lines.indices.contains(index) else { return nil }
        let text = lyricsService.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }


    private var artworkColor: Color {
        ArtworkColorCache.shared.color(for: player.currentTrack?.parentThumb ?? player.currentTrack?.thumb) ?? .gray
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let isPortrait = height >= width
            let showsMiniLyricsSlot = miniLyricsModeEnabled
                && !showLyrics
                && !showQueue
                && isPortrait
                && lyricsService.hasSynced
                && !lyricsService.lines.isEmpty
            let baseArtworkWidth = width - 64.0
            let baseArtworkHeight = height * 0.5
            let artworkSize = max(min(baseArtworkWidth, baseArtworkHeight), 2.0)
            let isPadLandscape = UIDevice.current.userInterfaceIdiom == .pad && geo.size.width > geo.size.height
            let isPadPortrait = UIDevice.current.userInterfaceIdiom == .pad && geo.size.height > geo.size.width
            let controlsContainerWidth = isPadPortrait ? artworkSize : nil
            let controlsHorizontalPadding: CGFloat = isPadPortrait ? 0 : AppStyle.Spacing.nowPlayingHorizontal
            let landscapeOuterHorizontalPadding: CGFloat = 40
            let landscapeColumnSpacing: CGFloat = 36
            let landscapeContentWidth = max(0.0, width - (landscapeOuterHorizontalPadding * 2))
            let landscapeLeftWidth = landscapeContentWidth * 0.4
            let landscapeRightWidth = max(0.0, landscapeContentWidth - landscapeLeftWidth - landscapeColumnSpacing)
            let landscapeControlsHorizontalPadding: CGFloat = 12
            let landscapeArtworkMaxByWidth = landscapeLeftWidth - (landscapeControlsHorizontalPadding * 2)
            let landscapeControlsHeight: CGFloat = 400
            let landscapeArtworkMaxByHeight = max(110.0, height - landscapeControlsHeight)
            let landscapeArtworkSize = max(110.0, min(landscapeArtworkMaxByWidth, landscapeArtworkMaxByHeight))


            let _ = applyInitialLandscapeLyrics(isPadLandscape: isPadLandscape)

            if isPadLandscape {
                VStack(spacing: 0) {
                    dragHandle
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    HStack(alignment: .top, spacing: landscapeColumnSpacing) {
                        VStack(spacing: 0) {
                            ArtworkView(
                                thumbPath: (player.currentTrack?.parentThumb ?? player.currentTrack?.thumb),
                                size: landscapeArtworkSize,
                                cornerRadius: 8
                            )
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                            .padding(.top, 10)

                            Spacer(minLength: 8)

                            trackInfo
                                .padding(.horizontal, landscapeControlsHorizontalPadding)
                                .padding(.bottom, 28)
                            controlsStack(horizontalPadding: landscapeControlsHorizontalPadding, bottomPadding: 4)
                                .layoutPriority(1)
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
                    .frame(maxHeight: .infinity)

                    // Bottom action row
                    HStack {
                        AirPlayButton(
                            tintOpacity: CGFloat(controlTintOpacity),
                            activeTintOpacity: CGFloat(actionIconActiveOpacity)
                        )
                        .frame(width: 46, height: 46)

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
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.title3.weight(.semibold))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .padding(.horizontal, landscapeOuterHorizontalPadding)
                    .padding(.bottom, (geo.safeAreaInsets.bottom > 0 ? 2 : 6) + iPadBottomActionsExtraPadding)
                }
                .animation(.easeInOut(duration: 0.25), value: showLyrics)
                .animation(.easeInOut(duration: 0.25), value: showQueue)
            } else {
                VStack(spacing: 0) {
                    dragHandle
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    if !isCompact {
                        Spacer(minLength: 16)
                    }

                    // Artwork header — scales between full and compact
                    HStack(spacing: 12) {
                        ArtworkView(
                            thumbPath: (player.currentTrack?.parentThumb ?? player.currentTrack?.thumb),
                            size: isCompact ? 62 : artworkSize,
                            cornerRadius: 8
                        )
                        .shadow(color: .black.opacity(isCompact ? 0.3 : 0.5), radius: isCompact ? 8 : 40, y: isCompact ? 4 : 20)
                        .scaleEffect(!isCompact && player.isPlaying ? 1.0 : !isCompact ? 0.85 : 1.0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

                        if isCompact {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.currentTrack?.title ?? "Not Playing")
                                    .font(.callout.bold())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(player.currentTrack?.artistDisplayName ?? "")
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))

                            Spacer()

                            trackContextMenu
                        }
                    }
                    .frame(maxWidth: isCompact ? .infinity : nil)
                    .padding(.horizontal, isCompact ? 32 : 0)
                    .padding(.top, isCompact ? 8 : 0)
                    .padding(.bottom, showsMiniLyricsSlot ? 0 : portraitArtworkBottomPadding)
                    .offset(y: 0)
                    .zIndex(1)

                    // Content area when compact
                    if isCompact {
                        lyricsQueueContent
                            .transaction { $0.animation = nil }
                    }

                    if showsMiniLyricsSlot {
                        Spacer(minLength: 0)
                        MiniLyricsLineView(text: activeMiniLyricText ?? " ")
                            .padding(.horizontal, controlsHorizontalPadding)
                            .transition(.opacity)
                        Spacer(minLength: 0)
                    } else {
                        Spacer()
                    }

                    // Bottom controls — pinned to bottom
                    VStack(spacing: 0) {
                        if !isCompact {
                            trackInfo
                                .padding(.horizontal, controlsHorizontalPadding)
                                .padding(.bottom, portraitTrackInfoBottomPadding)
                                .transition(.opacity)
                        }
                        controlsStack(horizontalPadding: controlsHorizontalPadding, isPadPortrait: isPadPortrait)
                        bottomActions
                            .frame(height: 32)
                            .padding(.horizontal, controlsHorizontalPadding)
                            .padding(.bottom, isPadPortrait ? iPadBottomActionsExtraPadding : 0)
                    }
                    .frame(maxWidth: controlsContainerWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 8 : 16)
                }
                .animation(.easeInOut(duration: 0.4), value: isCompact)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showsMiniLyricsSlot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { NowPlayingBackground() }
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
                            Text("Loading Lyrics…")
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
                        VStack(spacing: 12) {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("No Lyrics Available")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var trackInfo: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Menu {
                    trackContextMenuItems
                } label: {
                    Text(player.currentTrack?.artistDisplayName ?? "")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 16) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(player.isShuffled ? 1 : 0.4))
                }

                Button { player.cycleRepeatMode() } label: {
                    Image(systemName: player.repeatMode.iconName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(player.repeatMode.isActive ? 1 : 0.4))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
    }

    // MARK: - Controls Stack

    private func controlsStack(
        horizontalPadding: CGFloat,
        bottomPadding: CGFloat = 20,
        isPadPortrait: Bool = false
    ) -> some View {
        let sliderBottomPadding: CGFloat = isPadPortrait ? 42 : 28
        let transportBottomPadding: CGFloat = isPadPortrait ? 64 : 52
        let volumeBottomPadding: CGFloat = isPadPortrait ? 38 : (bottomPadding + 6)

        return VStack(spacing: 0) {
            TimelineSlider()
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, sliderBottomPadding)
            transportControls
                .frame(height: 56)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, transportBottomPadding)
            VolumeSlider(isEnabled: true)
                .frame(height: 32)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, volumeBottomPadding)
        }
    }

    // MARK: - Track Context Menu

    @ViewBuilder
    private var trackContextMenuItems: some View {
        if let track = player.currentTrack {
            if let artistKey = track.grandparentRatingKey {
                Button {
                    let artist = PlexMetadata(
                        ratingKey: artistKey, key: nil, type: "artist", subtype: nil,
                        title: track.grandparentTitle ?? track.artistName,
                        titleSort: nil, originalTitle: nil, summary: nil, studio: nil, year: nil,
                        index: nil, parentIndex: nil, duration: nil, addedAt: nil,
                        updatedAt: nil, viewCount: nil, lastViewedAt: nil, userRating: nil,
                        thumb: track.grandparentThumb, art: nil, parentThumb: nil,
                        grandparentThumb: nil, grandparentArt: nil, parentTitle: nil,
                        grandparentTitle: nil, parentRatingKey: nil,
                        grandparentRatingKey: nil, leafCount: nil, viewedLeafCount: nil,
                        media: nil, genre: nil, style: nil, country: nil,
                        subformat: nil, originallyAvailableAt: nil
                    )
                    onNavigate?(artist)
                    dismiss()
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
            if let albumKey = track.parentRatingKey {
                Button {
                    let album = PlexMetadata(
                        ratingKey: albumKey, key: nil, type: "album", subtype: nil,
                        title: track.parentTitle ?? "",
                        titleSort: nil, originalTitle: nil, summary: nil, studio: nil, year: nil,
                        index: nil, parentIndex: nil, duration: nil, addedAt: nil,
                        updatedAt: nil, viewCount: nil, lastViewedAt: nil, userRating: nil,
                        thumb: track.parentThumb ?? track.thumb, art: nil, parentThumb: nil,
                        grandparentThumb: nil, grandparentArt: nil,
                        parentTitle: track.grandparentTitle ?? track.artistName,
                        grandparentTitle: nil, parentRatingKey: nil,
                        grandparentRatingKey: nil, leafCount: nil, viewedLeafCount: nil,
                        media: nil, genre: nil, style: nil, country: nil,
                        subformat: nil, originallyAvailableAt: nil
                    )
                    onNavigate?(album)
                    dismiss()
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
    }

    private var trackContextMenu: some View {
        Menu {
            trackContextMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, height: 32)
        }
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
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .contentTransition(.symbolEffect(.replace))
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
                .frame(width: 46, height: 46)

            Spacer()

            Button {
                toggleQueuePanel()
            } label: {
                panelToggleIcon(systemName: "list.bullet", isActive: showQueue)
            }
            .buttonStyle(.plain)
            .padding(.trailing, bottomActionsTrailingButtonPadding)
        }
        .font(.title3.weight(.semibold))
    }

    @discardableResult
    private func applyInitialLandscapeLyrics(isPadLandscape: Bool) -> Bool {
        if !appliedInitialLandscapeLyrics, startPanel == .none, isPadLandscape {
            DispatchQueue.main.async {
                showQueue = false
                showLyrics = true
                appliedInitialLandscapeLyrics = true
            }
        }
        return true
    }

    private func toggleLyricsPanel() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            if showLyrics {
                showLyrics = false
            } else {
                showQueue = false
                showLyrics = true
            }
        }
    }

    private func toggleQueuePanel() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            if showQueue {
                showQueue = false
            } else {
                showLyrics = false
                showQueue = true
            }
        }
    }

    @ViewBuilder
    private func panelToggleIcon(systemName: String, isActive: Bool) -> some View {
        if isActive {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(actionBackgroundActiveOpacity))
                Image(systemName: systemName)
                    .foregroundStyle(.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 38, height: 38)
            .animation(.none, value: isActive)
        } else {
            Image(systemName: systemName)
                .foregroundStyle(.white.opacity(actionIconInactiveOpacity))
                .frame(width: 38, height: 38)
                .animation(.none, value: isActive)
        }
    }
}

// MARK: - Timeline Slider

struct TimelineSlider: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var isDragging = false
    @State private var sliderValue: TimeInterval = 0

    var body: some View {
        let duration = max(player.duration, 1)
        let isReady = player.isReadyToPlay || player.hasTrack

        VStack(spacing: 6) {
            Slider(
                value: $sliderValue,
                in: 0...duration,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        player.seek(to: sliderValue)
                    }
                }
            )
            .tint(.white)
            .disabled(!isReady)
            .opacity(isReady ? 1 : 0.5)

            HStack {
                Text(formatTime(sliderValue))
                Spacer()
                Text("-\(formatTime(max(0, duration - sliderValue)))")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .monospacedDigit()
        }
        .onChange(of: player.currentTime) { _, newValue in
            if !isDragging {
                withAnimation(.linear(duration: 0.1)) {
                    sliderValue = min(newValue, duration)
                }
            }
        }
        .onChange(of: player.currentTrack?.ratingKey) { _, _ in
            if !isDragging {
                sliderValue = player.currentTime
            }
        }
        .onChange(of: player.duration) { _, newDuration in
            if !isDragging {
                sliderValue = min(sliderValue, max(newDuration, 0))
            }
        }
        .onAppear {
            sliderValue = player.currentTime
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - AirPlay (AVRoutePickerView)

struct AirPlayButton: UIViewRepresentable {
    var tintOpacity: CGFloat = 0.7
    var activeTintOpacity: CGFloat = 0.92

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.tintColor = UIColor.white.withAlphaComponent(tintOpacity)
        picker.activeTintColor = UIColor.white.withAlphaComponent(activeTintOpacity)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor.white.withAlphaComponent(tintOpacity)
        uiView.activeTintColor = UIColor.white.withAlphaComponent(activeTintOpacity)
    }
}

// MARK: - Volume Slider

struct VolumeSlider: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.tintColor = .white
        for subview in view.subviews where subview is UIButton {
            subview.removeFromSuperview()
        }
        configure(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: MPVolumeView) {
        view.isUserInteractionEnabled = isEnabled
        view.alpha = isEnabled ? 1 : 0.5
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                slider.isEnabled = isEnabled
                slider.alpha = isEnabled ? 1 : 0.5
            }
        }
    }
}

// MARK: - Dynamic Color Background

struct NowPlayingBackground: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    private var thumbPath: String? {
        player.currentTrack?.parentThumb ?? player.currentTrack?.thumb
    }

    private var artworkColor: Color {
        ArtworkColorCache.shared.color(for: thumbPath) ?? .gray
    }

    var body: some View {
        LinearGradient(
            colors: [artworkColor, .black],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: artworkColor)
        .task(id: thumbPath) {
            guard let server = serverConnection.currentServer else { return }
            await ArtworkColorCache.shared.resolveColor(
                for: thumbPath,
                using: client,
                server: server
            )
        }
    }
}


#Preview {
    NowPlayingView()
        .environment(AudioPlayerService())
}
