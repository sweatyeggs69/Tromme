import SwiftUI

struct LyricsScrollView: View {
    @Environment(AudioPlayerService.self) private var player
    let lyricsService: LyricsService

    @State private var containerHeight: CGFloat = 400
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    // Slinky advance: on a natural one-line advance the scroll jumps
    // instantly to the new position while nearby lines are pushed back to
    // where they were, then each line springs into place staggered by its
    // distance below the active line — Apple Music's cascade.
    @State private var lineMidYs: [UUID: CGFloat] = [:]
    @State private var slinkyOffsets: [UUID: CGFloat] = [:]

    /// Highlight lines slightly ahead of their timestamp so the active lyric
    /// is already in place when it's sung.
    private static let lyricLeadTime: TimeInterval = 0.15

    /// How many lines around the active one take part in the cascade —
    /// generous enough to cover everything on screen.
    private static let slinkyWindowAbove = 10
    private static let slinkyWindowBelow = 15

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var lineFontSize: CGFloat { isPad ? 44 : 32 }

    private var currentIndex: Int {
        lyricsService.currentLineIndex(at: player.currentTime + Self.lyricLeadTime)
    }

    private var bufferHeight: CGFloat {
        max(0, containerHeight / 2 - 30)
    }

    var body: some View {
        Group {
            if !lyricsService.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 24) {
                            Color.clear.frame(height: bufferHeight)

                            ForEach(Array(lyricsService.lines.enumerated()), id: \.element.id) { i, line in
                                lyricLine(text: line.text, isActive: i == currentIndex)
                                    .id(line.id)
                                    .onGeometryChange(for: CGFloat.self) { proxy in
                                        proxy.frame(in: .named("lyricsContent")).midY
                                    } action: { midY in
                                        lineMidYs[line.id] = midY
                                    }
                                    .offset(y: slinkyOffsets[line.id] ?? 0)
                                    .onTapGesture {
                                        player.seek(to: line.time)
                                        scrollResumeTask?.cancel()
                                        isUserScrolling = false
                                    }
                            }

                            Color.clear.frame(height: bufferHeight)
                        }
                        .padding(.horizontal, 20)
                        .coordinateSpace(.named("lyricsContent"))
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        containerHeight = max(0, height)
                    }
                    .onAppear {
                        guard currentIndex < lyricsService.lines.count else { return }
                        proxy.scrollTo(lyricsService.lines[currentIndex].id, anchor: .center)
                    }
                    .onChange(of: currentIndex) { oldIndex, newIndex in
                        guard newIndex < lyricsService.lines.count, !isUserScrolling else { return }
                        advance(from: oldIndex, to: newIndex, proxy: proxy)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { _ in
                                isUserScrolling = true
                                scrollResumeTask?.cancel()
                            }
                            .onEnded { _ in
                                scrollResumeTask = Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    isUserScrolling = false
                                    if currentIndex < lyricsService.lines.count {
                                        withAnimation(.spring(duration: 0.7, bounce: 0.15)) {
                                            proxy.scrollTo(lyricsService.lines[currentIndex].id, anchor: .center)
                                        }
                                    }
                                }
                            }
                    )
                }
            } else if lyricsService.isInstrumental {
                lyricsNotice("Instrumental")
            } else if let plainLyrics = lyricsService.plainLyrics, !plainLyrics.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(plainLyrics)
                        .font(isPad ? .title.weight(.semibold) : .title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 40)
                }
            } else {
                lyricsNotice("No Lyrics Available")
            }
        }
    }

    /// Advances the lyrics with an Apple Music-style cascade: the scroll jumps
    /// instantly to center the new line while every nearby line is pushed back
    /// down by the same distance (net zero movement on screen), then each line
    /// springs into place, staggered by its distance below the active line.
    ///
    /// Only the natural next-line advance cascades. Seeks, taps, and the index
    /// churn from a stream restart re-center with a plain smooth scroll so the
    /// view always converges on the active line.
    private func advance(from oldIndex: Int, to newIndex: Int, proxy: ScrollViewProxy) {
        let lines = lyricsService.lines
        let targetID = lines[newIndex].id

        guard newIndex == oldIndex + 1,
              lines.indices.contains(oldIndex),
              let oldY = lineMidYs[lines[oldIndex].id],
              let newY = lineMidYs[targetID] else {
            recenter(on: targetID, proxy: proxy)
            return
        }

        let delta = newY - oldY
        guard delta > 0, delta < containerHeight / 2 else {
            recenter(on: targetID, proxy: proxy)
            return
        }

        let window = max(0, newIndex - Self.slinkyWindowAbove)..<min(lines.count, newIndex + Self.slinkyWindowBelow)
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            proxy.scrollTo(targetID, anchor: .center)
            for i in window {
                slinkyOffsets[lines[i].id] = delta
            }
        }
        // Release on the next runloop tick so the settle registers as its own
        // change; explicit withAnimation carries each line's staggered spring.
        Task { @MainActor in
            for i in window {
                withAnimation(.spring(duration: 0.8, bounce: 0.2).delay(slinkyDelay(for: i, activeIndex: newIndex))) {
                    slinkyOffsets[lines[i].id] = 0
                }
            }
        }
    }

    private func recenter(on targetID: UUID, proxy: ScrollViewProxy) {
        withAnimation(.spring(duration: 0.7, bounce: 0.15)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    private func slinkyDelay(for index: Int, activeIndex: Int) -> Double {
        let distance = index - activeIndex
        guard distance > 0 else { return 0 }
        return min(Double(distance) * 0.055, 0.44)
    }

    private func lyricLine(text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: lineFontSize, weight: .bold))
            .foregroundStyle(.white.opacity(isActive ? 1.0 : 0.3))
            .blur(radius: isActive ? 0 : 1.2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .scaleEffect(isActive ? 1.08 : 0.90)
            .animation(.spring(duration: 0.7, bounce: 0.2), value: isActive)
    }

    private func lyricsNotice(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.3))
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    LyricsScrollView(lyricsService: LyricsService())
        .environment(AudioPlayerService())
        .background(.black)
}
