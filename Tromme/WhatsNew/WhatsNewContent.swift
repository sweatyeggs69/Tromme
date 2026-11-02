import Foundation

enum WhatsNewContent {
    static let isEnabled = true

    static let current = WhatsNewRelease(
        id: "2026.11.1",
        title: "What's New in Tromme",
        features: [
            WhatsNewFeature(
                symbol: <#T##String#>, title: <#T##String#>, text: <#T##String#>
            
            WhatsNewFeature(
                symbol: "waveform.path",
                title: "AutoMix",
                text: "Songs now crossfade from the last lyric of one to the first lyric of the next. (Tromme +)"
            ),
            WhatsNewFeature(
                symbol: "slider.horizontal.3",
                title: "Mixing in Settings",
                text: "Configure AutoMix and Crossfade in Settings > Playback."
            ),
            WhatsNewFeature(
                symbol: "tag",
                title: "Tag Picker",
                text: "Set genre, style and mood tags when editing."
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
