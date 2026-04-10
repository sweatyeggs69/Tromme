import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    let album: PlexMetadata

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true

    var body: some View {
        List {
            // Header
            Section {
                VStack(spacing: 12) {
                    ArtworkView(thumbPath: album.thumb, size: 220, cornerRadius: 10)
                        .shadow(radius: 12, y: 6)

                    Text(album.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    if let artistName = album.parentTitle {
                        Text(artistName)
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }

                    HStack(spacing: 4) {
                        if let genre = album.genre?.first?.tag {
                            Text(genre)
                        }
                        if album.genre?.first?.tag != nil && album.year != nil {
                            Text("·")
                        }
                        if let year = album.year {
                            Text(String(year))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }

            // Play / Shuffle
            Section {
                HStack(spacing: 12) {
                    Button {
                        player.play(tracks: tracks)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)

                    Button {
                        var shuffled = tracks
                        shuffled.shuffle()
                        player.play(tracks: shuffled)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)
                }
                .listRowSeparator(.hidden)
            }

            // Tracks
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else {
                let discNumbers = Set(tracks.compactMap(\.parentIndex)).sorted()
                let multiDisc = discNumbers.count > 1

                ForEach(discNumbers.isEmpty ? [1] : discNumbers, id: \.self) { disc in
                    let discTracks = multiDisc ? tracks.filter { $0.parentIndex == disc } : tracks

                    if multiDisc {
                        Section("Disc \(disc)") {
                            trackRows(discTracks)
                        }
                    } else {
                        Section {
                            trackRows(discTracks)
                        }
                    }
                }

                // Footer
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if let year = album.year {
                            Text("Released \(String(year))")
                        }
                        if !tracks.isEmpty {
                            let totalMin = tracks.compactMap(\.duration).reduce(0, +) / 60000
                            Text("\(tracks.count) songs, \(totalMin) minutes")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTracks() }
    }

    private func trackRows(_ discTracks: [PlexMetadata]) -> some View {
        ForEach(Array(discTracks.enumerated()), id: \.element.id) { index, track in
            let globalIndex = tracks.firstIndex(where: { $0.ratingKey == track.ratingKey }) ?? index
            TrackRowView(track: track, tracks: tracks, index: globalIndex)
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            tracks = try await client.cachedChildren(server: server, ratingKey: album.ratingKey)
        } catch {}
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        AlbumDetailView(album: PlexMetadata(
            ratingKey: "1", key: nil, type: "album", title: "Midnights",
            titleSort: nil, originalTitle: nil, summary: nil, year: 2022,
            index: nil, parentIndex: nil, duration: nil, addedAt: nil,
            updatedAt: nil, viewCount: nil, lastViewedAt: nil,
            thumb: nil, art: nil, parentThumb: nil, grandparentThumb: nil,
            grandparentArt: nil, parentTitle: "Taylor Swift",
            grandparentTitle: nil, parentRatingKey: nil,
            grandparentRatingKey: nil, leafCount: 13, viewedLeafCount: nil,
            media: nil, genre: [PlexTag(tag: "Pop")], country: nil
        ))
    }
    .environment(AudioPlayerService())
}
