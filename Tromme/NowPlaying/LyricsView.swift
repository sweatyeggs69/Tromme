import SwiftUI

struct LyricsScrollView: View {
    @Environment(AudioPlayerService.self) private var player
    let lyricsService: LyricsService

    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false

    @State private var containerHeight: CGFloat = 400
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    @State private var clock = LyricsClock()


    /// Height of the top/bottom fade mask NowPlayingView applies around this
    /// view — content needs at least this much clearance so lines aren't
    /// faded out or clipped at the edges.
    private static let edgeFadeHeight: CGFloat = 80

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var lineFontSize: CGFloat { isPad ? 44 : 32 }

    /// The active line is derived from the extrapolated clock and re-checked
    /// often, otherwise closely timed lines would switch up to half a second
    /// late and then have to catch up.
    @State private var currentIndex = 0
    /// The line the view last jumped to without animation, so the index change
    /// that jump causes doesn't also trigger an animated scroll to the same line.
    @State private var settledIndex: Int?

    private func lineIndex(at date: Date = .now) -> Int {
        lyricsService.currentLineIndex(at: clock.time(at: date))
    }

    /// Positions the view on the active line with no animation.
    private func jumpToActiveLine(proxy: ScrollViewProxy) {
        let index = lineIndex()
        currentIndex = index
        settledIndex = index
        guard lyricsService.lines.indices.contains(index) else { return }
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            proxy.scrollTo(lyricsService.lines[index].id, anchor: .center)
        }
    }

    private func updateCurrentIndex() {
        let index = lineIndex()
        if index != currentIndex { currentIndex = index }
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
                                lyricLine(line, isActive: i == currentIndex)
                                    .id(line.id)
                                    .onTapGesture {
                                        player.seek(to: line.time)
                                        scrollResumeTask?.cancel()
                                        isUserScrolling = false
                                    }
                            }

                            Color.clear.frame(height: bufferHeight)
                        }
                        .padding(.horizontal, leftAlignLyrics ? 0 : 20)
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        containerHeight = max(0, height)
                    }
                    .onAppear {
                        clock = LyricsClock(anchorTime: player.currentTime, anchorDate: .now, isPlaying: player.isPlaying, advance: LyricsClock.defaultAdvance)
                        jumpToActiveLine(proxy: proxy)
                    }
                    .onChange(of: containerHeight) { _, _ in
                        // The buffers above and below the lines depend on the height, so the
                        // first real measurement (or a rotation) shifts the content.
                        guard !isUserScrolling else { return }
                        jumpToActiveLine(proxy: proxy)
                    }
                    .background {
                        // Re-checks the active line every frame while playing, since the
                        // player's own time only updates twice a second.
                        TimelineView(.animation(paused: !player.isPlaying)) { context in
                            Color.clear.onChange(of: lineIndex(at: context.date)) { _, newIndex in
                                if newIndex != currentIndex { currentIndex = newIndex }
                            }
                        }
                    }
                    .onChange(of: lyricsService.lines.first?.id) { _, _ in
                        jumpToActiveLine(proxy: proxy)
                    }
                    .onChange(of: currentIndex) { _, newIndex in
                        guard newIndex != settledIndex else { return }
                        settledIndex = nil
                        guard newIndex < lyricsService.lines.count, !isUserScrolling else { return }
                        recenter(on: lyricsService.lines[newIndex].id, proxy: proxy)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { _ in
                                isUserScrolling = true
                                scrollResumeTask?.cancel()
                            }
                            .onEnded { _ in
                                guard player.isPlaying else { return }
                                scheduleScrollResume(proxy: proxy)
                            }
                    )
                    .onChange(of: player.currentTime) { _, time in
                        clock = LyricsClock(anchorTime: time, anchorDate: .now, isPlaying: player.isPlaying, advance: LyricsClock.defaultAdvance)
                        updateCurrentIndex()
                    }
                    .onChange(of: player.isPlaying) { _, isPlaying in
                        clock = LyricsClock(anchorTime: player.currentTime, anchorDate: .now, isPlaying: isPlaying, advance: LyricsClock.defaultAdvance)
                        guard isPlaying, isUserScrolling else { return }
                        scheduleScrollResume(proxy: proxy)
                    }
                }
            } else if lyricsService.isInstrumental {
                lyricsNotice("Instrumental")
            } else if let plainLyrics = lyricsService.plainLyrics, !plainLyrics.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Clears the fade mask NowPlayingView wraps around this view,
                        // matching the buffer LyricsScrollView keeps for synced lyrics
                        // so the first line isn't faded/clipped against the top edge.
                        Color.clear.frame(height: Self.edgeFadeHeight)

                        Text(plainLyrics)
                            .font(isPad ? .largeTitle.weight(.semibold) : .title2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(leftAlignLyrics ? .leading : .center)
                            .frame(maxWidth: .infinity, alignment: leftAlignLyrics ? .leading : .center)
                            .padding(.horizontal, leftAlignLyrics ? 0 : 20)

                        Color.clear.frame(height: Self.edgeFadeHeight)
                    }
                }
            } else {
                lyricsNotice("No Lyrics Available")
            }
        }
    }

    /// Only auto-scrolls back to the focused lyric while playback is active;
    /// if paused, the user's manual scroll position is left alone until
    /// playback resumes (see the `player.isPlaying` onChange above).
    private func scheduleScrollResume(proxy: ScrollViewProxy) {
        scrollResumeTask?.cancel()
        scrollResumeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            isUserScrolling = false
            if currentIndex < lyricsService.lines.count {
                withAnimation(.spring(duration: 0.7, bounce: 0.15)) {
                    proxy.scrollTo(lyricsService.lines[currentIndex].id, anchor: .center)
                }
            }
        }
    }

    private func recenter(on targetID: UUID, proxy: ScrollViewProxy) {
        withAnimation(.spring(duration: 0.7, bounce: 0.15)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    @ViewBuilder
    private func lyricLineText(_ line: LyricsLine, isActive: Bool) -> some View {
        if line.isBreak {
            Image(systemName: "music.note")
                .accessibilityLabel("Instrumental break")
        } else if line.words.isEmpty {
            Text(line.text)
        } else {
            WordSyncedLyricText(
                words: line.words,
                isActive: isActive,
                clock: clock
            )
        }
    }

    private func lyricLine(_ line: LyricsLine, isActive: Bool) -> some View {
        VStack(spacing: 6) {
            lyricLineText(line, isActive: isActive)
                .font(.system(size: lineFontSize, weight: .bold))
                .frame(maxWidth: .infinity, alignment: leftAlignLyrics ? .leading : .center)
            // Backing vocals sing alongside the primary, smaller and just below it.
            ForEach(line.backing) { backing in
                lyricLineText(backing, isActive: isActive)
                    .font(.system(size: lineFontSize * 0.75, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.7)
            }
        }
            // Word-synced lines dim their own text in WordWipeTextRenderer.
            .foregroundStyle(.white.opacity(isActive || !line.words.isEmpty ? 1.0 : 0.3))
            .blur(radius: isActive ? 0 : 1.2)
            .multilineTextAlignment(leftAlignLyrics ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: leftAlignLyrics ? .leading : .center)
            .contentShape(Rectangle())
            .scaleEffect(isActive ? (leftAlignLyrics ? 1.0 : 1.08) : 0.90, anchor: leftAlignLyrics ? .leading : .center)
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
