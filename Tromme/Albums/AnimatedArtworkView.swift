import SwiftUI

struct AnimatedArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var isHeld = false
    var onFrame: ((UIImage) -> Void)?

    @Environment(NetworkStatus.self) private var network
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var isReady = false

    private var videoURL: URL? { network.isConnected ? url : nil }

    var body: some View {
        Group {
            if let videoURL {
                LoopingVideoView(url: videoURL, isPlaying: isOnScreen && scenePhase == .active, isHeld: isHeld, isReady: $isReady, onFrame: onFrame)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(isReady ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: isReady)
        .onChange(of: videoURL) { isReady = false }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .allowsHitTesting(false)
    }
}

#Preview {
    AnimatedArtworkView(url: nil)
        .frame(width: 200, height: 200)
        .environment(NetworkStatus.shared)
}
