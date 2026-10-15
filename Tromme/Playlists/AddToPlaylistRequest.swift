import SwiftUI

struct AddToPlaylistRequest: Identifiable {
    let id = UUID()
    let itemRatingKeys: [String]
}
