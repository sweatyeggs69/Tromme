import SwiftUI

struct QueueView: View {
    var player: AudioPlayerService

    var body: some View {
        List {
            queueActions
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 4, trailing: 24))

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("404 Queue Not Found...")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(player.upcomingTracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        player.playFromQueue(at: index)
                    } label: {
                        QueueRow(track: track)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.1))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                .onMove { source, destination in
                    player.moveInQueue(from: source, to: destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    private var queueActions: some View {
        HStack(spacing: 10) {
            QueueActionPill(systemImage: "shuffle", isActive: player.isShuffled) {
                player.toggleShuffle()
            }
            .frame(maxWidth: .infinity)

            QueueActionPill(systemImage: player.repeatMode.iconName, isActive: player.repeatMode.isActive) {
                player.cycleRepeatMode()
            }
            .frame(maxWidth: .infinity)

            QueueActionPill(systemImage: "wand.and.stars", isActive: false) {
                // Placeholder action for future Magic Ward behavior.
            }
            .frame(maxWidth: .infinity)
        }
        .font(.body.weight(.semibold))
    }
}

private struct QueueActionPill: View {
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(isActive ? .white : .white.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(isActive ? 0.24 : 0.10))
                }
        }
        .buttonStyle(.plain)
    }
}

private struct QueueRow: View {
    let track: PlexMetadata

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(
                thumbPath: track.thumb ?? track.parentThumb,
                size: 44,
                cornerRadius: 6
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ZStack {
        Color.black
        QueueView(player: AudioPlayerService())
    }
}
