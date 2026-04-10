import Testing
@testable import Tromme

// Helper to create PlexMetadata from JSON for testing
private func decodeMetadata(_ json: String) throws -> PlexMetadata {
    try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
}

private func decodeSection(_ json: String) throws -> LibrarySection {
    try JSONDecoder().decode(LibrarySection.self, from: Data(json.utf8))
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
