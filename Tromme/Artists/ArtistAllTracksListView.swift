import SwiftUI

struct ArtistAllTracksListView: View {
    @Environment(AudioPlayerService.self) private var player

    let tracks: [PlexMetadata]
    let albums: [PlexMetadata]
    @State private var trackNavigationTarget: PlexMetadata?
    @AppStorage("artistAllTracksSortNewestFirst") private var sortNewestFirst = true

    private var albumReleaseInfo: [String: (date: String, year: Int)] {
        Dictionary(
            albums.map { ($0.ratingKey, (date: $0.originallyAvailableAt ?? "", year: $0.year ?? 0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var sortedTracks: [PlexMetadata] {
        let releaseInfo = albumReleaseInfo
        return tracks.sorted { lhs, rhs in
            let leftInfo = lhs.parentRatingKey.flatMap { releaseInfo[$0] }
            let rightInfo = rhs.parentRatingKey.flatMap { releaseInfo[$0] }

            let leftDate = leftInfo?.date ?? lhs.originallyAvailableAt ?? ""
            let rightDate = rightInfo?.date ?? rhs.originallyAvailableAt ?? ""
            if leftDate != rightDate {
                return sortNewestFirst ? (leftDate > rightDate) : (leftDate < rightDate)
            }

            let leftYear = leftInfo?.year ?? lhs.year ?? 0
            let rightYear = rightInfo?.year ?? rhs.year ?? 0
            if leftYear != rightYear {
                return sortNewestFirst ? (leftYear > rightYear) : (leftYear < rightYear)
            }

            let leftAlbum = lhs.parentTitle ?? ""
            let rightAlbum = rhs.parentTitle ?? ""
            if leftAlbum != rightAlbum {
                return leftAlbum.localizedStandardCompare(rightAlbum) == .orderedAscending
            }

            let leftDisc = lhs.parentIndex ?? 0
            let rightDisc = rhs.parentIndex ?? 0
            if leftDisc != rightDisc { return leftDisc < rightDisc }

            return (lhs.index ?? 0) < (rhs.index ?? 0)
        }
    }

    var body: some View {
        List {
            ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                TrackRowView(
                    track: track,
                    tracks: sortedTracks,
                    index: index,
                    showArtwork: true,
                    showArtist: true,
                    showTrackNumber: false,
                    artworkSize: AppStyle.TrackList.browseArtworkSize,
                    artworkCornerRadius: AppStyle.TrackList.artworkCornerRadius,
                    onNavigate: { trackNavigationTarget = $0 }
                )
                .listRowInsets(AppStyle.TrackList.rowInsets)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(AppStyle.TrackList.rowSpacing)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $trackNavigationTarget) { target in
            if target.type == "artist" {
                ArtistDetailView(artist: target)
            } else {
                AlbumDetailView(album: target)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sortNewestFirst.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .symbolEffect(.bounce, value: sortNewestFirst)
                }
                .tint(.primary)
                .accessibilityLabel(sortNewestFirst ? "Newest First" : "Oldest First")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    player.play(tracks: sortedTracks, startingAt: 0)
                } label: {
                    Image(systemName: "play.fill")
                }
                .tint(.primary)
                .disabled(sortedTracks.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var shuffled = sortedTracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled, startingAt: 0)
                } label: {
                    Image(systemName: "shuffle")
                }
                .tint(.primary)
                .disabled(sortedTracks.isEmpty)
            }
        }
    }
}
