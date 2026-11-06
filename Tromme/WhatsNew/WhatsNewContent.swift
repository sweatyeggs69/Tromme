import Foundation

enum WhatsNewContent {
    static let isEnabled = true

    static let current = WhatsNewRelease(
        id: "2026.11.6",
        title: "What's New in Tromme",
        features: [
            WhatsNewFeature(
                symbol: "car",
                title: "CarPlay",
                text: "Home follows your app's order, Playlists has its own tab, and Artists and Albums jump by letter."
            ),
            WhatsNewFeature(
                symbol: "ellipsis.circle",
                title: "CarPlay Now Playing",
                text: "A More button adds Favorite, Play Next and Add to Queue. AutoMix gets its own button. (Tromme +)"
            ),
            WhatsNewFeature(
                symbol: "music.note.list",
                title: "Playlists",
                text: "Long-press to change artwork, and rename from the menu."
            ),
            WhatsNewFeature(
                symbol: "house",
                title: "Faster Home",
                text: "Each section appears as soon as it loads."
            )
        ]
    )

    static var pending: WhatsNewRelease? { isEnabled ? current : nil }
}
