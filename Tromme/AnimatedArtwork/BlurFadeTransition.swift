import SwiftUI

/// Fades and blurs in place, with no scaling (unlike `.blurReplace`).
struct BlurFadeTransition: Transition {
    var radius: CGFloat = 20

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : radius)
    }
}
