import Foundation

enum WhatsNewContent {
    static let isEnabled = true

    static let current = WhatsNewRelease(
        id: "2026.11.3",
        title: "What's New in Tromme",
        features: [
            WhatsNewFeature(
                symbol: "house",
                title: "Your Home",
                text: "Choose and reorder Plex hubs in Settings > Home. Home now loads instantly, even offline."
            ),
            WhatsNewFeature(
                symbol: "waveform.path",
                title: "Crossfade",
                text: "Blend songs together and pick the length in Settings > Playback."
            ),
            WhatsNewFeature(
                symbol: "wand.and.stars",
                title: "AutoMix",
                text: "Smarter crossfades timed from the last lyric of one song to the first of the next. (Tromme +)"
            ),
            WhatsNewFeature(
                symbol: "gift",
                title: "Try Tromme +",
                text: "New subscribers get a free week of AutoMix, animated artwork, track trim and more."
            ),
            WhatsNewFeature(
                symbol: "internaldrive",
                title: "Music Cache",
                text: "Keeps the playing song and the next ones in your queue on your device. Turn it on in Settings > Playback."
            ),
            WhatsNewFeature(
                symbol: "text.quote",
                title: "Lyrics Offline",
                text: "Downloaded songs keep their lyrics."
            ),
            WhatsNewFeature(
                symbol: "tag",
                title: "Tags",
                text: "Edit genre, style and mood on artists and albums."
            ),
            WhatsNewFeature(
                symbol: "mic",
                title: "Siri",
                text: "Say \"Play Abbey Road in Tromme\" to start music hands-free."
            )
        ]
    )

    static var pending: WhatsNewRelease? { isEnabled ? current : nil }
}
