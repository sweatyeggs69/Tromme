import Foundation

struct WhatsNewFeature: Identifiable {
    let symbol: String
    let title: String
    let text: String

    var id: String { title }
}
