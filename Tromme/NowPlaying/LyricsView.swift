import SwiftUI

struct LyricsScrollView: View {
    @Environment(AudioPlayerService.self) private var player
    let lyricsService: LyricsService

    @State private var containerHeight: CGFloat = 400
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    private var currentIndex: Int {
        lyricsService.currentLineIndex(at: player.currentTime)
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
                                    .onTapGesture {
                                        player.seek(to: line.time)
                                        scrollResumeTask?.cancel()
                                        isUserScrolling = false
                                    }
                            }

                            Color.clear.frame(height: bufferHeight)
                        }
                        .padding(.horizontal, 32)
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
                    .onChange(of: currentIndex) { _, newIndex in
                        guard newIndex < lyricsService.lines.count, !isUserScrolling else { return }
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo(lyricsService.lines[newIndex].id, anchor: .center)
                        }
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
                                        withAnimation(.easeInOut(duration: 0.5)) {
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
                        .font(.title3.weight(.semibold))
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

    private func lyricLine(text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(.white.opacity(isActive ? 1.0 : 0.3))
            .blur(radius: isActive ? 0 : 1.2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .scaleEffect(isActive ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.35), value: isActive)
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
