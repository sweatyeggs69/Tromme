import AVFoundation

@MainActor
final class LocalLosslessPlayer: NSObject, AVAudioPlayerDelegate {
    private let audioPlayer: AVAudioPlayer
    var onFinish: (() -> Void)?

    init(url: URL) throws {
        audioPlayer = try AVAudioPlayer(contentsOf: url)
        super.init()
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
    }

    var duration: TimeInterval { audioPlayer.duration }
    var isPlaying: Bool { audioPlayer.isPlaying }

    var currentTime: TimeInterval {
        get { audioPlayer.currentTime }
        set { audioPlayer.currentTime = max(0, min(newValue, audioPlayer.duration)) }
    }

    var volume: Float {
        get { audioPlayer.volume }
        set { audioPlayer.volume = newValue }
    }

    func play() { audioPlayer.play() }
    func pause() { audioPlayer.pause() }

    func stop() {
        onFinish = nil
        audioPlayer.delegate = nil
        audioPlayer.stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.onFinish?()
        }
    }
}
