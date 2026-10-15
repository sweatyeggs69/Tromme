import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct ArtworkSlotAnchorsKey: PreferenceKey {
    static var defaultValue: [ArtworkAnimationSlot: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [ArtworkAnimationSlot: Anchor<CGRect>], nextValue: () -> [ArtworkAnimationSlot: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
