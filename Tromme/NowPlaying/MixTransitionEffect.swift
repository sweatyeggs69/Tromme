import SwiftUI

/// Plays over the Now Playing artwork when Auto Mix hands over to the next track:
/// light rings ripple outward, a sheen sweeps across the cover, and a glass badge
/// with a live waveform stays for the length of the overlap.
struct MixTransitionEffect: View {
    var cornerRadius: CGFloat

    @Environment(AudioPlayerService.self) private var player

    @State private var isActive = false
    @State private var ripple = false
    @State private var sweep: CGFloat = -1
    @State private var playbackTask: Task<Void, Never>?

    private static let ringCount = 3

    var body: some View {
        ZStack {
            ForEach(0..<Self.ringCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 2
                    )
                    .scaleEffect(ripple ? 1.28 + 0.12 * CGFloat(index) : 1)
                    .opacity(ripple ? 0 : (isActive ? 0.9 : 0))
                    .animation(.easeOut(duration: 1.5).delay(Double(index) * 0.2), value: ripple)
            }

            GeometryReader { proxy in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.5), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.6)
                .offset(x: sweep * proxy.size.width)
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isActive ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            if isActive {
                badge
                    .padding(.bottom, 14)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isActive)
        .allowsHitTesting(false)
        .onChange(of: player.autoMixTransition) { _, transition in
            guard let transition else { return }
            play(transition)
        }
        .onDisappear { playbackTask?.cancel() }
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Image(systemName: player.autoMixTransition?.isBeatMatched == true ? "metronome" : "waveform")
                .symbolEffect(.variableColor.iterative.reversing, isActive: isActive)
            Text("Auto Mix")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
    }

    private func play(_ transition: AutoMixTransition) {
        playbackTask?.cancel()
        playbackTask = Task {
            ripple = false
            sweep = -1
            isActive = true
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            ripple = true
            withAnimation(.easeInOut(duration: 1.3)) { sweep = 1.4 }
            try? await Task.sleep(for: .seconds(max(transition.duration, 2.5)))
            guard !Task.isCancelled else { return }
            isActive = false
            ripple = false
        }
    }
}

#Preview {
    RoundedRectangle(cornerRadius: 6)
        .fill(.gray)
        .frame(width: 300, height: 300)
        .overlay { MixTransitionEffect(cornerRadius: 6) }
        .padding(60)
        .background(.black)
        .environment(AudioPlayerService())
}
