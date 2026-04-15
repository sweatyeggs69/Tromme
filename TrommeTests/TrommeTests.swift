import Testing
import Foundation
@testable import Tromme

// Helper to create PlexMetadata from JSON for testing
private func decodeMetadata(_ json: String) throws -> PlexMetadata {
    try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
}

private func decodeSection(_ json: String) throws -> LibrarySection {
    try JSONDecoder().decode(LibrarySection.self, from: Data(json.utf8))
}

private func makeServer() -> PlexServer {
    PlexServer(
        name: "Test Server",
        uri: "https://example.plex.direct:32400",
        machineIdentifier: "machine-123",
        accessToken: "token-abc",
        connections: []
    )
}

@Test func plexMetadataDurationFormatted() throws {
    let track = try decodeMetadata("""
    {"ratingKey":"1","title":"Test","type":"track","index":1,"duration":234000}
    """)
    #expect(track.durationFormatted == "3:54")
}

@Test func plexMetadataArtistName() throws {
    let track = try decodeMetadata("""
    {"ratingKey":"2","title":"Song","type":"track","parentTitle":"Album","grandparentTitle":"Artist"}
    """)
    #expect(track.artistName == "Artist")
    #expect(track.albumName == "Album")
}

@Test func plexMetadataFlexibleRatingKey() throws {
    // ratingKey as integer (common in Plex responses)
    let track = try decodeMetadata("""
    {"ratingKey":12345,"title":"Test"}
    """)
    #expect(track.ratingKey == "12345")
}

@Test func librarySectionIsMusicLibrary() throws {
    let music = try decodeSection("""
    {"key":"1","type":"artist","title":"Music"}
    """)
    let movie = try decodeSection("""
    {"key":"2","type":"movie","title":"Movies"}
    """)
    #expect(music.isMusicLibrary == true)
    #expect(movie.isMusicLibrary == false)
}

@Test func librarySectionNumericType() throws {
    // type as integer (Plex type number 8 = artist)
    let section = try decodeSection("""
    {"key":3,"type":8,"title":"My Music"}
    """)
    #expect(section.key == "3")
    #expect(section.type == "artist")
    #expect(section.isMusicLibrary == true)
}

@Test func artworkRecommendedTranscodeSizeBuckets() {
    #expect(ArtworkView.recommendedTranscodeSize(pointSize: 44, displayScale: 3) == 160)
    #expect(ArtworkView.recommendedTranscodeSize(pointSize: 72, displayScale: 3) == 256)
    #expect(ArtworkView.recommendedTranscodeSize(pointSize: 120, displayScale: 3) == 384)
    #expect(ArtworkView.recommendedTranscodeSize(pointSize: 180, displayScale: 3) == 640)
}

@Test func plexAPIClientArtworkURLIncludesExpectedQuery() throws {
    let client = PlexAPIClient()
    let server = makeServer()
    let url = try #require(client.artworkURL(server: server, path: "/library/metadata/123/thumb/456", width: 256, height: 512))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

    #expect(components.path == "/photo/:/transcode")
    #expect(items["width"] == "256")
    #expect(items["height"] == "512")
    #expect(items["minSize"] == "1")
    #expect(items["upscale"] == "1")
    #expect(items["url"] == "/library/metadata/123/thumb/456")
    #expect(items["X-Plex-Token"] == server.accessToken)
    #expect(items["X-Plex-Client-Identifier"] == PlexAPIClient.clientIdentifier)
}

@Test func plexAPIClientArtworkURLReturnsNilForMissingPath() {
    let client = PlexAPIClient()
    let server = makeServer()
    #expect(client.artworkURL(server: server, path: nil) == nil)
    #expect(client.artworkURL(server: server, path: "") == nil)
}

@Test func plexAPIClientUniversalStreamURLCandidatesNormalizePath() throws {
    let client = PlexAPIClient()
    let server = makeServer()
    let urls = client.universalStreamURLCandidates(
        server: server,
        mediaPathCandidates: ["library/metadata/99"],
        sessionID: "session-1"
    )
    let url = try #require(urls.first)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

    #expect(components.path == "/music/:/transcode/universal/start.m3u8")
    #expect(items["path"] == "/library/metadata/99")
    #expect(items["directStream"] == "1")
    #expect(items["protocol"] == "hls")
    #expect(items["X-Plex-Token"] == server.accessToken)
}

@Test func plexAPIClientPlaybackHeadersIncludeSessionIdentifier() {
    let client = PlexAPIClient()
    let server = makeServer()
    let headers = client.playbackHeaders(server: server, sessionID: "session-42", cellular: true)

    #expect(headers["X-Plex-Token"] == server.accessToken)
    #expect(headers["X-Plex-Session-Identifier"] == "session-42")
    #expect(headers["X-Plex-Client-Profile-Extra"] == PlexAPIClient.profileExtraCellular)
}

#if DEBUG
@Test func imageCacheDebugMemoryKeyBucketsBy32Pixels() throws {
    let url = try #require(URL(string: "https://example.com/art.jpg"))
    let keyA = ImageCache.debugMemoryKey(for: url, targetPixelSize: 250)
    let keyB = ImageCache.debugMemoryKey(for: url, targetPixelSize: 255)
    let keyC = ImageCache.debugMemoryKey(for: url, targetPixelSize: 260)
    #expect(keyA == keyB)
    #expect(keyA != keyC)
}

@Test func imageCacheDebugStatsTrackMemoryClear() async {
    await ImageCache.shared.resetDebugStats()
    await ImageCache.shared.clearMemory()
    let stats = await ImageCache.shared.debugStatsSnapshot()
    #expect(stats.memoryClears >= 1)
}
#endif
