import Foundation

enum WhatsNewContent {
    static let isEnabled = true

    static let current = WhatsNewRelease(
        id: "2026.11.1",
        title: "What's New in Tromme",
        features: [
            WhatsNewFeature(
                symbol: "waveform.path",
                title: "Smarter AutoMix",
                text: "Songs now crossfade from the last lyric of one to the first lyric of the next."
            ),
            WhatsNewFeature(
                symbol: "slider.horizontal.3",
                title: "Mixing in Settings",
                text: "Turn AutoMix and Crossfade on from Settings > Playback."
            ),
            WhatsNewFeature(
                symbol: "tag",
                title: "Tag Picker",
                text: "Search your library's genre, style and mood tags when editing."
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
