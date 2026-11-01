import AppIntents

struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays an artist, album, song or playlist from your Plex library.")

    @Parameter(title: "Music", requestValueDialog: "What do you want to play?")
    var item: MusicItemEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let tracks = try await MusicItemResolver.tracks(for: item)
        let player = AppContext.shared.audioPlayer
        if player.isShuffled != shuffle { player.toggleShuffle() }
        player.play(tracks: tracks, startingAt: 0)
        return .result()
    }
}
