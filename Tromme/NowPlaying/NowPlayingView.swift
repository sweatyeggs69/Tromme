import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingView: View {
    // MARK: - Environment

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyricsService = LyricsService()
    @State private var isVisible = false

    // MARK: - Layout Constants

    private let bottomActionsLeadingButtonPadding: CGFloat = 48
    private let bottomActionsTrailingButtonPadding: CGFloat = 48
    private let actionIconActiveOpacity: Double = 0.92
    private let actionIconInactiveOpacity: Double = 0.62
    private let actionBackgroundOpacity: Double = 0.12
    private let controlTintOpacity: Double = 0.82

    // MARK: - Computed Properties

    private var isCompact: Bool { showLyrics || showQueue }

    private var artworkColor: Color {
        ArtworkColorCache.shared.color(for: player.currentTrack?.thumb ?? player.currentTrack?.parentThumb) ?? .gray
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let artworkSize = min(geo.size.width - 64, geo.size.height * 0.5)

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
                        thumbPath: (player.currentTrack?.thumb ?? player.currentTrack?.parentThumb),
                        size: isCompact ? 62 : artworkSize,
                        cornerRadius: isCompact ? 8 : 12
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
                            Text(player.currentTrack?.artistName ?? "")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        .transition(.opacity)

                        Spacer()
                    }
                }
                .frame(maxWidth: isCompact ? .infinity : nil)
                .padding(.horizontal, isCompact ? 24 : 0)
                .padding(.top, isCompact ? 8 : 0)
                .padding(.bottom, 10)
                .zIndex(1)

                // Content area when compact
                if isCompact {
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
                                                    .frame(height: 40)
                                                Color.white
                                                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                                                    .frame(height: 40)
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
                    .transaction { $0.animation = nil }
                }

                Spacer()

                // Bottom controls — pinned to bottom
                VStack(spacing: 0) {
                    if !isCompact {
                        trackInfo
                            .padding(.horizontal, 32)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                    TimelineSlider()
                        .padding(.horizontal, 32)
                        .padding(.bottom, 20)
                    transportControls
                        .frame(height: 56)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 38)
                    VolumeSlider()
                        .frame(height: 32)
                        .padding(.horizontal, 36)
                        .padding(.bottom, 20)
                    bottomActions
                        .frame(height: 32)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 8 : 16)
            }
            .animation(.easeInOut(duration: 0.4), value: isCompact)
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
                Text(player.currentTrack?.artistName ?? "")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
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
            } label: {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(.white.opacity(showLyrics ? actionIconActiveOpacity : actionIconInactiveOpacity))
                    .frame(width: 38, height: 38)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(actionBackgroundOpacity))
                            .opacity(showLyrics ? 1 : 0)
                    }
                    .animation(.none, value: showLyrics)
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
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.white.opacity(showQueue ? actionIconActiveOpacity : actionIconInactiveOpacity))
                    .frame(width: 38, height: 38)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(actionBackgroundOpacity))
                            .opacity(showQueue ? 1 : 0)
                    }
                    .animation(.none, value: showQueue)
            }
            .buttonStyle(.plain)
            .padding(.trailing, bottomActionsTrailingButtonPadding)
        }
        .font(.title3.weight(.semibold))
    }
}

// MARK: - Timeline Slider

struct TimelineSlider: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    private var displayTime: TimeInterval {
        isDragging ? dragTime : player.currentTime
    }

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { displayTime },
                    set: { dragTime = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragTime = player.currentTime
                        isDragging = true
                    } else {
                        player.seek(to: dragTime)
                        isDragging = false
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(formatTime(displayTime))
                Spacer()
                Text("-\(formatTime(max(0, player.duration - displayTime)))")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .monospacedDigit()
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
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white.withAlphaComponent(0.38)
        DispatchQueue.main.async {
            for subview in view.subviews where subview is UIButton {
                subview.removeFromSuperview()
            }
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Dynamic Color Background

struct NowPlayingBackground: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    private var thumbPath: String? {
        player.currentTrack?.thumb ?? player.currentTrack?.parentThumb
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
