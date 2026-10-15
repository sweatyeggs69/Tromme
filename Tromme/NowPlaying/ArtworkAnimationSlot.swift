import SwiftUI
import AVKit
import MediaPlayer
import UIKit

/// Marks where the shared Now Playing artwork should sit — either its full-size
/// resting spot, or the small thumbnail spot next to the track title when the
/// Queue/Lyrics panel is open. A single floating artwork view is positioned
/// between these two measured rects so it visually shrinks/slides between them
/// instead of two separate views cross-fading (which looks like a duplicate).
enum ArtworkAnimationSlot: Hashable {
    case full
    case compact
}
