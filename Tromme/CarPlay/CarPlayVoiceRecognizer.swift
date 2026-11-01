import AVFoundation
import Speech

@MainActor
final class CarPlayVoiceRecognizer {
    enum Failure: Error {
        case denied, unavailable, nothingHeard
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var latest = ""
    private var timerTask: Task<Void, Never>?

    func listen() async throws -> String {
        guard await Self.authorize() else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw Failure.unavailable }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish(.failure(error))
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    self?.handle(text: text, isFinal: isFinal, failed: failed)
                }
            }
            schedule(after: .seconds(8))
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            latest = text
            schedule(after: .seconds(1.5))
        }
        if isFinal || failed {
            finish(latest.isEmpty ? .failure(Failure.nothingHeard) : .success(latest))
        }
    }

    private func schedule(after delay: Duration) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.finish(self.latest.isEmpty ? .failure(Failure.nothingHeard) : .success(self.latest))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        timerTask?.cancel()
        timerTask = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    private static func authorize() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speechAllowed else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
