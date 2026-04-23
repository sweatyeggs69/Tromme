import SwiftUI

struct QueueView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    var player: AudioPlayerService
    @AppStorage("magicMixStyleMatch") private var magicMixStyleMatch = 2
    @State private var isBuildingMagicMix = false
    @State private var magicMixPreviousKeys: Set<String> = []
    @State private var infinitePreviousKeys: Set<String> = []

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
                            Task { await buildAndQueueMagicMix() }
                        } else if isInfiniteModeActive {
                            Task { await fillInfiniteQueue() }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, AppStyle.Spacing.nowPlayingHorizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
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
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.1))
                        .listRowInsets(EdgeInsets(top: 6, leading: AppStyle.Spacing.nowPlayingHorizontal, bottom: 6, trailing: AppStyle.Spacing.nowPlayingHorizontal))
                    }
                    .onMove { source, destination in
                        player.moveInQueue(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: player.currentIndex) { _, _ in
            if isMagicMixActive, player.upcomingTracks.count <= 1 {
                Task { await buildAndQueueMagicMix() }
            }
            if isInfiniteModeActive, player.upcomingTracks.count < 5 {
                Task { await fillInfiniteQueue() }
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
                    Task { await fillInfiniteQueue() }
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
                    Task { await buildAndQueueMagicMix() }
                }
            }
            .disabled(isInfiniteModeActive)
            .opacity(isInfiniteModeActive ? 0.45 : 1)
            .frame(maxWidth: .infinity)
        }
        .font(.callout.weight(.semibold))
    }

    @MainActor
    private func buildAndQueueMagicMix() async {
        guard !isBuildingMagicMix else { return }
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }

        isBuildingMagicMix = true
        defer { isBuildingMagicMix = false }

        guard let currentTrack = player.currentTrack,
              let seedAlbumKey = currentTrack.parentRatingKey else { return }

        guard let allTracks = try? await client.magicMixTracks(
            server: server,
            sectionId: sectionId,
            seedTrackKey: currentTrack.ratingKey,
            seedAlbumKey: seedAlbumKey,
            seedArtistKey: currentTrack.grandparentRatingKey,
            limit: 50,
            minMatchingStyles: magicMixStyleMatch
        ), !allTracks.isEmpty else { return }

        // Favor tracks not in the previous batch, then shuffle the final selection
        let fresh = allTracks.filter { !magicMixPreviousKeys.contains($0.ratingKey) }
        let selected: [PlexMetadata]
        if fresh.count >= 25 {
            selected = Array(fresh.shuffled().prefix(25))
        } else {
            let repeats = allTracks.filter { magicMixPreviousKeys.contains($0.ratingKey) }
            selected = Array((fresh + repeats).prefix(25)).shuffled()
        }

        magicMixPreviousKeys = Set(selected.map(\.ratingKey))

        for track in selected {
            player.addToEndOfQueue(track)
        }
    }

    @MainActor
    private func fillInfiniteQueue() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }

        let needed = 5 - player.upcomingTracks.count
        guard needed > 0 else { return }

        let allTracks = (try? await client.cachedTracks(server: server, sectionId: sectionId)) ?? []
        guard !allTracks.isEmpty else { return }

        let fresh = allTracks.filter { !infinitePreviousKeys.contains($0.ratingKey) }
        let pool = fresh.isEmpty ? allTracks : fresh
        let selected = Array(pool.shuffled().prefix(needed))

        for key in selected.map(\.ratingKey) {
            infinitePreviousKeys.insert(key)
        }
        // Prevent the set from growing indefinitely
        if infinitePreviousKeys.count > allTracks.count / 2 {
            infinitePreviousKeys.removeAll()
        }

        for track in selected {
            player.addToEndOfQueue(track)
        }
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
                size: 44,
                cornerRadius: 8
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
