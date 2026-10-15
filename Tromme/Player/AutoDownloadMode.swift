import Foundation
import Observation

enum AutoDownloadMode: String, CaseIterable {
    case library
    case queue

    static let defaultMode: AutoDownloadMode = .queue

    var displayName: String {
        switch self {
        case .library: "Entire Library"
        case .queue: "Dynamic"
        }
    }
}
