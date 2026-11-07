import SwiftUI

struct LyricsOffsetButton: View {
    @Environment(AudioPlayerService.self) private var player

    private var store: LyricsOffsetStore { .shared }
    private var offset: Int { store.offset(for: player.currentTrack) }
    private var isAdjusted: Bool { offset != LyricsOffsetStore.defaultOffset }

    private var offsetText: String {
        let seconds = Double(offset) / 1000
        return seconds.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false))) + " s"
    }

    var body: some View {
        Menu {
            Section("Lyrics Offset \(offsetText)") {
                ControlGroup {
                    Button("Later", systemImage: "minus") { adjust(by: -LyricsOffsetStore.step) }
                        .disabled(offset <= LyricsOffsetStore.range.lowerBound)
                    Button("Earlier", systemImage: "plus") { adjust(by: LyricsOffsetStore.step) }
                        .disabled(offset >= LyricsOffsetStore.range.upperBound)
                }
                .menuActionDismissBehavior(.disabled)

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    guard let track = player.currentTrack else { return }
                    store.setOffset(LyricsOffsetStore.defaultOffset, for: track)
                }
                .disabled(!isAdjusted)
            }
        } label: {
            Image(systemName: "clock")
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(player.currentTrack == nil)
        .accessibilityLabel("Lyrics Offset")
        .accessibilityValue(offsetText)
    }

    private func adjust(by delta: Int) {
        guard let track = player.currentTrack else { return }
        store.setOffset(offset + delta, for: track)
    }
}

#Preview {
    LyricsOffsetButton()
        .environment(AudioPlayerService())
        .padding()
        .background(.black)
}
