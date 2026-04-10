import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Binding var showNowPlaying: Bool

    private var isInline: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: isInline ? 12 : 8) {
            Button {
                showNowPlaying = true
            } label: {
                HStack(spacing: isInline ? 12 : 8) {
                    ArtworkView(
                        thumbPath: player.currentTrack?.thumb ?? player.currentTrack?.parentThumb,
                        size: isInline ? 30 : 36,
                        cornerRadius: isInline ? 8 : 6
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
                            Text(player.currentTrack?.artistName ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 4)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            playPauseButton
            forwardButton
        }
        .padding(.horizontal, isInline ? 8 : 0)
        .padding(.leading, isInline ? 0 : 16)
        .padding(.trailing, isInline ? 0 : 18)
        .padding(.vertical, isInline ? 0 : 8)
    }

    // MARK: - Controls

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
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
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MiniPlayerView(showNowPlaying: .constant(false))
        .environment(AudioPlayerService())
}
