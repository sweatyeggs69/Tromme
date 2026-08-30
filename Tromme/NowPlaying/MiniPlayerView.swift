import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Binding var showNowPlaying: Bool
    var openNowPlaying: (NowPlayingStartPanel) -> Void = { _ in }

    private var isInline: Bool { placement == .inline }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @State private var swipeOffset: CGFloat = 0
    @State private var swipeOpacity: Double = 1

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40, coordinateSpace: .local)
            .onEnded { value in
                if value.translation.width < -40 {
                    handleSwipe(goingNext: true)
                } else if value.translation.width > 40 {
                    handleSwipe(goingNext: false)
                }
            }
    }

    private func handleSwipe(goingNext: Bool) {
        if goingNext {
            let hasNext = player.currentIndex < player.queue.count - 1 || player.repeatMode != .off
            guard hasNext else { return }
        }
        let exitOffset: CGFloat = goingNext ? -120 : 120
        let entryOffset: CGFloat = goingNext ? 120 : -120
        withAnimation(.easeIn(duration: 0.12)) {
            swipeOffset = exitOffset
            swipeOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.12))
            if goingNext { player.next() } else { player.previous() }
            swipeOffset = entryOffset
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                swipeOffset = 0
                swipeOpacity = 1
            }
        }
    }

    private func openNowPlayingDefault() {
        openNowPlaying(.none)
        showNowPlaying = true
    }

 
    var body: some View {
        Group {
            if isPad {
                HStack(spacing: AppStyle.MiniPlayer.spacing) {
                    Button {
                        openNowPlayingDefault()
                    } label: {
                        HStack(spacing: AppStyle.MiniPlayer.spacingCompact) {
                            ArtworkView(
                                thumbPath: player.currentTrack?.parentThumb ?? player.currentTrack?.thumb,
                                size: AppStyle.MiniPlayer.artworkSize,
                                cornerRadius: AppStyle.MiniPlayer.artworkCornerRadius
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.currentTrack?.title ?? "")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .allowsTightening(true)
                                Text(player.currentTrack?.artistDisplayName ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .allowsTightening(true)
                            }
                        }
                        .offset(x: swipeOffset)
                        .opacity(swipeOpacity)
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 2) {
                        shuffleButton
                        previousButton
                        playPauseButton
                        forwardButton
                        repeatButton
                    }
                    .fixedSize()
                    .layoutPriority(1)

                    HStack(spacing: 2) {
                        airPlayButton
                        queueButton
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.leading, AppStyle.MiniPlayer.leadingPadding)
                .padding(.trailing, AppStyle.MiniPlayer.trailingPadding)
                .padding(.vertical, AppStyle.MiniPlayer.verticalPadding)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded {
                        openNowPlayingDefault()
                    },
                    including: .gesture
                )
                .highPriorityGesture(swipeGesture)
            } else {
                HStack(spacing: isInline ? AppStyle.MiniPlayer.spacing : AppStyle.MiniPlayer.spacingCompact) {
                    Button {
                        openNowPlayingDefault()
                    } label: {
                        HStack(spacing: isInline ? AppStyle.MiniPlayer.spacing : AppStyle.MiniPlayer.spacingCompact) {
                            ArtworkView(
                                thumbPath: player.currentTrack?.parentThumb ?? player.currentTrack?.thumb,
                                size: isInline ? AppStyle.MiniPlayer.artworkSizeInline : AppStyle.MiniPlayer.artworkSize,
                                cornerRadius: AppStyle.MiniPlayer.artworkCornerRadius
                            )

                            if isInline {
                                Text(player.currentTrack?.title ?? "")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(player.currentTrack?.title ?? "")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text(player.currentTrack?.artistDisplayName ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()
                        }
                        .offset(x: swipeOffset)
                        .opacity(swipeOpacity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    playPauseButton
                    forwardButton
                }
                .padding(.horizontal, isInline ? AppStyle.MiniPlayer.spacingCompact : 0)
                .padding(.leading, isInline ? 0 : AppStyle.MiniPlayer.leadingPadding)
                .padding(.trailing, isInline ? 0 : AppStyle.MiniPlayer.trailingPadding)
                .padding(.vertical, isInline ? 0 : AppStyle.MiniPlayer.verticalPadding)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded {
                        openNowPlayingDefault()
                    },
                    including: .gesture
                )
                .highPriorityGesture(swipeGesture)
            }
        }
    }

    // MARK: - Controls

    private var shuffleButton: some View {
        Button {
            player.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(player.isShuffled ? 1 : 0.45))
                .frame(width: AppStyle.MiniPlayer.secondaryControlSize, height: AppStyle.MiniPlayer.controlSize)
        }
        .buttonStyle(.plain)
    }

    private var previousButton: some View {
        Button {
            player.previous()
        } label: {
            Image(systemName: "backward.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: AppStyle.MiniPlayer.controlSize, height: AppStyle.MiniPlayer.controlSize)
        }
        .buttonStyle(.plain)
    }

    private var playPauseButton: some View {
        let size = isPad ? AppStyle.MiniPlayer.playPauseSizePad : AppStyle.MiniPlayer.controlSize
        return Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(isPad ? .title.weight(.semibold) : .title2)
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }

    private var forwardButton: some View {
        Button {
            player.next()
        } label: {
            Image(systemName: "forward.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: AppStyle.MiniPlayer.controlSize, height: AppStyle.MiniPlayer.controlSize)
        }
        .buttonStyle(.plain)
    }

    private var repeatButton: some View {
        Button {
            player.cycleRepeatMode()
        } label: {
            Image(systemName: player.repeatMode.iconName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(player.repeatMode.isActive ? 1 : 0.45))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: AppStyle.MiniPlayer.secondaryControlSize, height: AppStyle.MiniPlayer.controlSize)
        }
        .buttonStyle(.plain)
    }

    private var lyricsButton: some View {
        Button {
            openNowPlaying(.lyrics)
            showNowPlaying = true
        } label: {
            Image(systemName: "quote.bubble")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(AppStyle.NowPlaying.actionIconActiveOpacity))
                .frame(width: AppStyle.MiniPlayer.secondaryControlSize, height: AppStyle.MiniPlayer.controlSize)
        }
        .buttonStyle(.plain)
    }

    private var queueButton: some View {
        Button {
            openNowPlaying(.queue)
            showNowPlaying = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(AppStyle.NowPlaying.actionIconActiveOpacity))
                .frame(width: AppStyle.MiniPlayer.secondaryControlSize, height: AppStyle.MiniPlayer.controlSize)
        }
        .buttonStyle(.plain)
    }

    private var airPlayButton: some View {
        AirPlayButton(tintOpacity: 0.7, activeTintOpacity: 0.92)
            .frame(width: AppStyle.MiniPlayer.secondaryControlSize, height: AppStyle.MiniPlayer.controlSize)
    }

}

#Preview {
    MiniPlayerView(showNowPlaying: .constant(false))
        .environment(AudioPlayerService())
}
