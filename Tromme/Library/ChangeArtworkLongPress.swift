import SwiftUI

extension View {
    /// Long press opens the artwork changer, with a light haptic as confirmation.
    func changeArtworkOnLongPress(isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(ChangeArtworkLongPress(isEnabled: isEnabled, action: action))
    }
}

private struct ChangeArtworkLongPress: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void
    @State private var feedbackTrigger = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.5) {
                guard isEnabled else { return }
                feedbackTrigger += 1
                action()
            }
            .sensoryFeedback(.impact, trigger: feedbackTrigger)
    }
}
