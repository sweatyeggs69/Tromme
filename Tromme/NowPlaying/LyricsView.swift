import SwiftUI

struct LyricsScrollView: View {
    @Environment(AudioPlayerService.self) private var player
    let lyricsService: LyricsService
    var isPadLandscape = false
    var isDuo = false

    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false

    @State private var containerHeight: CGFloat = 400
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    @State private var clock = LyricsClock()


    private static let edgeFadeHeight: CGFloat = 80

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var lineFontSize: CGFloat { isPadLandscape ? (isDuo ? 46 : 56) : (isPad ? 44 : 32) }

    @State private var currentIndex = 0
    @State private var isPositioned = false
    @State private var settledIndex: Int?

    private func lineIndex(at date: Date = .now) -> Int {
        lyricsService.currentLineIndex(at: clock.time(at: date))
    }

    private func jumpToActiveLine(proxy: ScrollViewProxy) {
        let index = lineIndex()
        settledIndex = index
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            currentIndex = index
            isPositioned = true
            guard lyricsService.lines.indices.contains(index) else { return }
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
                                lyricLine(line, isActive: isPositioned && i == currentIndex)
                                    .id(line.id)
                                    .onTapGesture {
                                        player.seek(to: line.time)
                                        scrollResumeTask?.cancel()
                                        isUserScrolling = false
                                    }
                            }

                            sourceFooter

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
                        guard !isUserScrolling else { return }
                        jumpToActiveLine(proxy: proxy)
                    }
                    .background {
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
                        Color.clear.frame(height: Self.edgeFadeHeight)

                        Text(plainLyrics)
                            .font(isPadLandscape ? .system(size: isDuo ? 32 : 40, weight: .semibold) : (isPad ? .largeTitle.weight(.semibold) : .title2.weight(.semibold)))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(leftAlignLyrics ? .leading : .center)
                            .frame(maxWidth: .infinity, alignment: leftAlignLyrics ? .leading : .center)
                            .padding(.horizontal, leftAlignLyrics ? 0 : 20)

                        sourceFooter
                            .padding(.top, 24)
                            .padding(.horizontal, leftAlignLyrics ? 0 : 20)

                        Color.clear.frame(height: Self.edgeFadeHeight)
                    }
                }
            } else {
                lyricsNotice("No Lyrics Available")
            }
        }
    }

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
            ForEach(line.backing) { backing in
                lyricLineText(backing, isActive: isActive)
                    .font(.system(size: lineFontSize * 0.75, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.7)
            }
        }
            .foregroundStyle(.white.opacity(isActive || !line.words.isEmpty ? 1.0 : 0.3))
            .blur(radius: isActive ? 0 : 1.2)
            .multilineTextAlignment(leftAlignLyrics ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: leftAlignLyrics ? .leading : .center)
            .contentShape(Rectangle())
            .scaleEffect(isActive ? (leftAlignLyrics ? 1.0 : 1.08) : 0.90, anchor: leftAlignLyrics ? .leading : .center)
            .animation(.spring(duration: 0.7, bounce: 0.2), value: isActive)
    }

    @ViewBuilder
    private var sourceFooter: some View {
        let parts = [
            lyricsService.current?.source.map { "Lyrics from \($0.displayName)" },
            lyricsService.blockedCount > 0 ? "\(lyricsService.blockedCount) blocked" : nil
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: leftAlignLyrics ? .leading : .center)
        }
    }

    private func lyricsNotice(_ text: String) -> some View {
        NowPlayingEmptyState(message: text, systemImage: "quote.bubble")
    }
}

#Preview {
    LyricsScrollView(lyricsService: LyricsService())
        .environment(AudioPlayerService())
        .background(.black)
}
