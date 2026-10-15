import SwiftUI

/// Silent, looping animated artwork laid over the static artwork. Renders nothing
/// until playback starts, then fades in, so the static artwork stays visible when there
/// is none or loading fails. Streams over HLS, so it only shows while online. Plays
/// only while on screen with the app active, restarting from the top each time.
struct AnimatedArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    @Environment(NetworkStatus.self) private var network
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var isReady = false

    private var videoURL: URL? { network.isConnected ? url : nil }

    var body: some View {
        Group {
            if let videoURL {
                LoopingVideoView(url: videoURL, isPlaying: isOnScreen && scenePhase == .active, isReady: $isReady)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(isReady ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: isReady)
        .onChange(of: videoURL) { isReady = false }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        // Long-press and taps go to the static artwork underneath.
        .allowsHitTesting(false)
    }
}

#Preview {
    AnimatedArtworkView(url: nil)
        .frame(width: 200, height: 200)
        .environment(NetworkStatus.shared)
}
