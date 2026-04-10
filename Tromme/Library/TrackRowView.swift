import SwiftUI

struct TrackRowView: View {
    @Environment(AudioPlayerService.self) private var player

    let track: PlexMetadata
    let tracks: [PlexMetadata]
    let index: Int
    var showArtwork: Bool = false
    var showArtist: Bool = false
    var showTrackNumber: Bool = true
    var artworkSize: CGFloat = 42
    var showsMenu: Bool = true
    var isCompact: Bool = false
    var titleFont: Font? = nil
    var artistFont: Font? = nil

    var body: some View {
        Button {
            player.play(tracks: tracks, startingAt: index)
        } label: {
            HStack(spacing: isCompact ? 8 : 10) {
                // Leading: track number or artwork
                if showArtwork {
                    ArtworkView(thumbPath: track.thumb ?? track.parentThumb, size: artworkSize, cornerRadius: 7)
                } else if showTrackNumber {
                    ZStack {
                        if isCurrentTrack && player.isPlaying {
                            NowPlayingBarsView()
                                .frame(width: 24, height: 16)
                        } else {
                            Text("\(track.index ?? (index + 1))")
                                .font(.body)
                                .monospacedDigit()
                                .foregroundStyle(isCurrentTrack ? Color.accentColor : .secondary)
                        }
                    }
                    .frame(width: 28, alignment: .center)
                }

                // Title + artist
                VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
                    Text(track.title)
                        .font(titleFont ?? (isCompact ? .caption : .body))
                        .lineLimit(1)
                        .foregroundStyle(isCurrentTrack ? Color.accentColor : .primary)

                    if showArtist {
                        Text(track.artistName)
                            .font(artistFont ?? (isCompact ? .caption2 : .caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if showsMenu {
                    Menu {
                        trackContextMenu
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
            }
            .appPlainRowItemStyle()
            .frame(height: isCompact ? 44 : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackContextMenu: some View {
        Button {
            player.play(tracks: tracks, startingAt: index)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            player.addToQueue(track)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            player.addToEndOfQueue(track)
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        Divider()

        if track.grandparentTitle != nil || track.parentTitle != nil {
            Button {
                // Navigate to artist - handled by parent
            } label: {
                Label("Go to Artist", systemImage: "person.fill")
            }
        }

        if track.parentRatingKey != nil {
            Button {
                // Navigate to album - handled by parent
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
    }

    private var isCurrentTrack: Bool {
        player.currentTrack?.ratingKey == track.ratingKey
    }
}

// MARK: - Now Playing Bars Animation (Apple Music equalizer indicator)

struct NowPlayingBarsView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .scaleEffect(y: isAnimating ? CGFloat.random(in: 0.3...1.0) : 0.4, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: Double.random(in: 0.3...0.6))
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}

#Preview {
    let track = PlexMetadata(
        ratingKey: "1", key: nil, type: "track", title: "Test Song",
        titleSort: nil, originalTitle: nil, summary: nil, year: nil,
        index: 1, parentIndex: nil, duration: 234000, addedAt: nil,
        updatedAt: nil, viewCount: nil, lastViewedAt: nil,
        thumb: nil, art: nil, parentThumb: nil, grandparentThumb: nil,
        grandparentArt: nil, parentTitle: "Test Album",
        grandparentTitle: "Test Artist", parentRatingKey: nil,
        grandparentRatingKey: nil, leafCount: nil, viewedLeafCount: nil,
        media: nil, genre: nil, country: nil
    )
    TrackRowView(track: track, tracks: [track], index: 0)
        .environment(AudioPlayerService())
}
