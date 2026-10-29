import AVFoundation
import SFBAudioEngine

/// Plays one track through SFBAudioEngine's AVAudioEngine player. It decodes FLAC, Opus,
/// Vorbis, MP3, AAC and ALAC, and seeks by sample. Remote tracks are read with HTTP range
/// requests, so nothing is saved to disk. Used for every track whose codec AVPlayer
/// handles poorly (see `AudioPlayerService.usesCoreAudioEngine`).
@MainActor
final class LocalLosslessPlayer: NSObject, AudioPlayer.Delegate {
    private let player = AudioPlayer()
    private var decoder: AudioDecoder?
    private let sourceURL: URL
    private let sampleRate: Double
    private var pendingStart: TimeInterval = 0
    private var started = false
    private var finished = false

    let duration: TimeInterval
    var onFinish: (() -> Void)?

    /// Opens the file or remote URL off the main thread and reads its exact length.
    static func open(url: URL) async throws -> LocalLosslessPlayer {
        let opened = try await Task.detached { try OpenedDecoder(url: url) }.value
        return LocalLosslessPlayer(opened: opened, url: url)
    }

    private init(opened: OpenedDecoder, url: URL) {
        decoder = opened.decoder
        sourceURL = url
        sampleRate = opened.decoder.processingFormat.sampleRate
        duration = sampleRate > 0 ? Double(opened.decoder.length) / sampleRate : 0
        super.init()
        player.delegate = self
    }

    var isPlaying: Bool { player.isPlaying }

    var currentTime: TimeInterval {
        get { started ? (player.currentTime ?? pendingStart) : pendingStart }
        set {
            let time = max(0, min(newValue, duration))
            pendingStart = time
            if started { _ = player.seek(time: time) }
        }
    }

    var volume: Float {
        get { player.mainMixerNode.outputVolume }
        set { player.mainMixerNode.outputVolume = newValue }
    }

    func play() {
        if finished {
            // A finished track restarts from the beginning (or the requested seek).
            guard let fresh = try? OpenedDecoder(url: sourceURL) else { return }
            decoder = fresh.decoder
            started = false
            finished = false
        }
        if !started {
            guard let decoder else { return }
            if pendingStart > 0 { try? decoder.seek(to: AVAudioFramePosition(pendingStart * sampleRate)) }
            started = true
            self.decoder = nil
            try? player.play(decoder)
        } else if player.isPaused {
            _ = player.resume()
        }
    }

    func pause() {
        if started { _ = player.pause() }
    }

    func stop() {
        onFinish = nil
        player.delegate = nil
        player.stop()
        decoder = nil
    }

    nonisolated func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor [weak self] in
            guard let self, self.started else { return }
            self.finished = true
            self.pendingStart = 0
            self.onFinish?()
        }
    }
}

/// An opened decoder handed between threads once; only one side touches it at a time.
private struct OpenedDecoder: @unchecked Sendable {
    let decoder: AudioDecoder

    init(url: URL) throws {
        let source: InputSource = url.isFileURL
            ? try InputSource(for: url)
            : HTTPInputSource(remoteURL: url, length: 0)
        let decoder = try AudioDecoder(inputSource: source)
        try decoder.open()
        self.decoder = decoder
    }
}
