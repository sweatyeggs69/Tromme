import Foundation
import Observation

@Observable @MainActor
final class TrackInfoViewModel {
    private(set) var track: PlexMetadata
    private(set) var isLoading = true

    init(track: PlexMetadata) {
        self.track = track
    }

    var media: PlexMedia? { track.media?.first }
    var part: PlexPart? { media?.part?.first }
    var audioStream: PlexStream? { part?.stream?.first { $0.streamType == 2 } ?? part?.stream?.first }

    var download: DownloadedTrackRecord? { AppContext.shared.downloadManager.records[track.ratingKey] }

    func load(server: PlexServer?, client: PlexAPIClient) async {
        defer { isLoading = false }
        guard let server,
              let fresh = try? await client.getMetadata(server: server, ratingKey: track.ratingKey) else { return }
        track = fresh
    }
}
