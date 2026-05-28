import SwiftUI

struct QueueView: View {
    var player: AudioPlayerService

    private var isMagicMixActive: Bool {
        get { player.isMagicMixActive }
        nonmutating set { player.isMagicMixActive = newValue }
    }

    private var isInfiniteModeActive: Bool {
        get { player.isInfiniteModeActive }
        nonmutating set { player.isInfiniteModeActive = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            queueActions
                .padding(.horizontal, AppStyle.Spacing.nowPlayingHorizontal)
                .padding(.top, 2)
                .padding(.bottom, 4)

            if !player.upcomingTracks.isEmpty {
                HStack {
                    Text("Playing Next")
                        .font(.subheadline.bold())
                    Spacer()
                    Button(isMagicMixActive ? "New Mix" : "Clear") {
                        player.clearQueue()
                        if isMagicMixActive {
                            player.requestMagicMixRefill(freshMix: true)
                        } else if isInfiniteModeActive {
                            player.requestInfiniteRefill()
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, AppStyle.Spacing.nowPlayingHorizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("404 Queue Not Found...")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(player.upcomingTracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.playFromQueue(at: index)
                        } label: {
                            QueueRow(track: track)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                player.removeFromQueue(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .tint(.red)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: AppStyle.Spacing.nowPlayingHorizontal, bottom: 4, trailing: AppStyle.Spacing.nowPlayingHorizontal))
                    }
                    .onMove { source, destination in
                        player.moveInQueue(from: source, to: destination)
                    }

                    if isInfiniteModeActive {
                        HStack {
                            Spacer()
                            Image(systemName: "infinity")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.4))
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
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

            QueueActionPill(systemImage: "infinity", isActive: isInfiniteModeActive) {
                if isInfiniteModeActive {
                    isInfiniteModeActive = false
                } else {
                    isMagicMixActive = false
                    isInfiniteModeActive = true
                    player.requestInfiniteRefill()
                }
            }
            .disabled(isMagicMixActive)
            .opacity(isMagicMixActive ? 0.45 : 1)
            .frame(maxWidth: .infinity)

            QueueActionPill(systemImage: "wand.and.stars", isActive: isMagicMixActive) {
                if isMagicMixActive {
                    isMagicMixActive = false
                    player.clearQueue()
                } else {
                    isInfiniteModeActive = false
                    player.clearQueue()
                    isMagicMixActive = true
                    player.requestMagicMixRefill(freshMix: true)
                }
            }
            .disabled(isInfiniteModeActive)
            .opacity(isInfiniteModeActive ? 0.45 : 1)
            .frame(maxWidth: .infinity)
        }
        .font(.callout.weight(.semibold))
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
                .frame(maxWidth: .infinity, minHeight: 36)
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
                thumbPath: track.parentThumb ?? track.thumb,
                size: 48,
                cornerRadius: 6
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artistDisplayName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

#Preview {
    ZStack {
        Color.black
        QueueView(player: AudioPlayerService())
    }
}
