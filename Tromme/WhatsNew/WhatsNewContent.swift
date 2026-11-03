import Foundation

enum WhatsNewContent {
    static let isEnabled = true

    static let current = WhatsNewRelease(
        id: "2026.11.3",
        title: "What's New in Tromme",
        features: [
            WhatsNewFeature(
                symbol: "gift",
                title: "Try Tromme +",
                text: "New subscribers get a free trial of AutoMix, animated artwork, track trim and more."
            ),
            WhatsNewFeature(
                symbol: "house",
                title: "Instant Home",
                text: "Home loads right away, even offline."
            ),
            WhatsNewFeature(
                symbol: "airplayaudio",
                title: "AirPlay",
                text: "Crossfade and AutoMix pause over AirPlay to keep audio clean."
            )
        ]
    )

    static var pending: WhatsNewRelease? { isEnabled ? current : nil }
}
