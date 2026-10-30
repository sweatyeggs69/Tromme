import AVFoundation
import MediaPlayer
import Network
import Observation

extension AudioPlayerService {
    // MARK: - Audio Session

    func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            logPlayback("audio_session_setup_failed", "error=\(error.localizedDescription)")
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await self?.activateAudioSession()
            } catch {
                self?.logPlayback("audio_session_setup_failed", "error=\(error.localizedDescription)")
            }
        }
    }

    func activateAudioSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AVAudioSession.sharedInstance().activate { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func prefetchGainMetadata() {
        guard !isConstrainedPlaybackPath, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        guard UserDefaults.standard.bool(forKey: Self.soundCheckKey),
              let client, let server else { return }
        gainPrefetchTask?.cancel()
        let upcoming = queue.dropFirst(currentIndex).prefix(11)
        let keys = upcoming.map(\.ratingKey)
        gainPrefetchTask = Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                let maxConcurrent = 3
                for key in keys {
                    guard !Task.isCancelled else { return }
                    if inFlight >= maxConcurrent {
                        await group.next()
                        inFlight -= 1
                    }
                    group.addTask {
                        _ = try? await client.cachedMetadata(server: server, ratingKey: key)
                    }
                    inFlight += 1
                }
                await group.waitForAll()
            }
        }
    }

    func prefetchUpcomingArtwork() {
        guard !isConstrainedPlaybackPath, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        guard let client, let server else { return }
        let upcoming = queue.dropFirst(currentIndex + 1).prefix(5)
        let urls = upcoming.compactMap { track in
            let path = track.parentThumb ?? track.thumb
            return client.artworkURL(server: server, path: path, width: 300, height: 300)
        }
        Task { await ImageCache.shared.prefetch(urls: urls) }
    }
}
