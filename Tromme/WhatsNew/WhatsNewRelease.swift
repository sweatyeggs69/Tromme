import Foundation

struct WhatsNewRelease: Identifiable {
    let id: String
    let title: String
    let features: [WhatsNewFeature]
}
