import SwiftUI

struct LyricsScrollView: View {
    @Environment(AudioPlayerService.self) private var player
    let lyricsService: LyricsService

    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false

    @State private var containerHeight: CGFloat = 400
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    /// Last playback time the player reported and when, so word-synced
    /// lines can extrapolate between the player's half-second updates.
    @State private var timeAnchor = (time: TimeInterval(0), date: Date.now)

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

    /// Height of the top/bottom fade mask NowPlayingView applies around this
    /// view — content needs at least this much clearance so lines aren't
    /// faded out or clipped at the edges.
    private static let edgeFadeHeight: CGFloat = 80

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var lineFontSize: CGFloat { isPad ? 44 : 32 }

    /// The player only publishes its time every half second, so the active
    /// line is derived from a time extrapolated from the last report and
    /// re-checked often. Otherwise closely timed lines would switch up to half
    /// a second late and then have to catch up.
    @State private var currentIndex = 0
    @State private var lastAdvanceDate = Date.distantPast

    /// Never extrapolate further than this past a report, so a stalled
    /// stream doesn't run the lyrics ahead of the audio.
    private static let maxExtrapolation: TimeInterval = 1

    /// A line-to-line cascade takes about this long to settle. A new advance
    /// arriving sooner retargets with a plain scroll instead of restarting
    /// the cascade from partway through the previous one.
    private static let cascadeDuration: TimeInterval = 1.0

    private var estimatedTime: TimeInterval {
        guard player.isPlaying else { return timeAnchor.time }
        return timeAnchor.time + min(max(Date.now.timeIntervalSince(timeAnchor.date), 0), Self.maxExtrapolation)
    }

    private var targetIndex: Int {
        lyricsService.currentLineIndex(at: estimatedTime + Self.lyricLeadTime)
    }

    private func updateCurrentIndex() {
        let index = targetIndex
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
                        .padding(.horizontal, leftAlignLyrics ? 0 : 20)
                        .coordinateSpace(.named("lyricsContent"))
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        containerHeight = max(0, height)
                    }
                    .onAppear {
                        let index = targetIndex
                        currentIndex = index
                        guard index < lyricsService.lines.count else { return }
                        proxy.scrollTo(lyricsService.lines[index].id, anchor: .center)
                    }
                    .task(id: player.isPlaying) {
                        updateCurrentIndex()
                        while player.isPlaying, !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(30))
                            updateCurrentIndex()
                        }
                    }
                    .onChange(of: lyricsService.lines.first?.id) { _, _ in
                        updateCurrentIndex()
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
                                guard player.isPlaying else { return }
                                scheduleScrollResume(proxy: proxy)
                            }
                    )
                    .onChange(of: player.currentTime, initial: true) { _, time in
                        timeAnchor = (time: time, date: .now)
                        updateCurrentIndex()
                    }
                    .onChange(of: player.isPlaying) { _, isPlaying in
                        timeAnchor = (time: player.currentTime, date: .now)
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
            slinkyOffsets.removeAll()
            if currentIndex < lyricsService.lines.count {
                withAnimation(.spring(duration: 0.7, bounce: 0.15)) {
                    proxy.scrollTo(lyricsService.lines[currentIndex].id, anchor: .center)
                }
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

        // A cascade still settling would be restarted from partway through, so
        // lines close together just retarget the scroll instead.
        let previousAdvance = lastAdvanceDate
        lastAdvanceDate = .now
        guard Date.now.timeIntervalSince(previousAdvance) > Self.cascadeDuration,
              newIndex == oldIndex + 1,
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
                anchorTime: timeAnchor.time,
                anchorDate: timeAnchor.date,
                isPlaying: player.isPlaying
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
