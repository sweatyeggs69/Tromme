import SwiftUI

struct LyricsScrollView: View {
    @Environment(AudioPlayerService.self) private var player
    let lyricsService: LyricsService

    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false

    @State private var containerHeight: CGFloat = 400
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    @State private var clock = LyricsClock()

    /// Highlight lines slightly ahead of their timestamp so the active lyric
    /// is already in place when it's sung.
    private static let lyricLeadTime: TimeInterval = 0.15

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

    private func lineIndex(at date: Date = .now) -> Int {
        lyricsService.currentLineIndex(at: clock.time(at: date) + Self.lyricLeadTime)
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
                        let index = lineIndex()
                        currentIndex = index
                        guard index < lyricsService.lines.count else { return }
                        proxy.scrollTo(lyricsService.lines[index].id, anchor: .center)
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
                        updateCurrentIndex()
                    }
                    .onChange(of: currentIndex) { _, newIndex in
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
                    .onChange(of: player.currentTime, initial: true) { _, time in
                        clock = LyricsClock(anchorTime: time, anchorDate: .now, isPlaying: player.isPlaying)
                        updateCurrentIndex()
                    }
                    .onChange(of: player.isPlaying) { _, isPlaying in
                        clock = LyricsClock(anchorTime: player.currentTime, anchorDate: .now, isPlaying: isPlaying)
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
        lyricLineText(line, isActive: isActive)
            .font(.system(size: lineFontSize, weight: .bold))
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
