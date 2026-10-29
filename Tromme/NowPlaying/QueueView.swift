import SwiftUI

struct QueueView: View {
    var player: AudioPlayerService
    @State private var magicMixAvailable = false

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
                    Button("Clear") {
                        player.clearQueue()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, AppStyle.Spacing.nowPlayingHorizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }

            if player.upcomingTracks.isEmpty {
                NowPlayingEmptyState(message: "404 Queue Not Found...", systemImage: "list.bullet")
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

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: player.currentTrack?.grandparentRatingKey) {
            magicMixAvailable = await player.magicMixAvailable()
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

            QueueActionPill(systemImage: "wand.and.stars", isActive: player.isMagicMixActive) {
                player.requestMagicMixRefill(freshMix: true)
            }
            .disabled(!magicMixAvailable)
            .opacity(!magicMixAvailable ? 0.45 : 1)
            .frame(maxWidth: .infinity)
        }
        .font(.callout.weight(.semibold))
    }

}

#Preview {
    ZStack {
        Color.black
        QueueView(player: AudioPlayerService())
    }
}
