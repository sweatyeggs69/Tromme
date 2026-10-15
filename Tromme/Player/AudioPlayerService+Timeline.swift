import AVFoundation
import MediaPlayer
import Network
import Observation

// Timeline and scrobble reporting.
extension AudioPlayerService {
    // MARK: - Timeline Reporting

    /// Best-effort lifecycle signal when the app is terminating.
    /// iOS may not deliver this on force-quit, but when it does we report stopped.
    func reportStoppedForAppTermination() {
        guard currentTrack != nil else { return }
        maybeReportScrobble()
        reportTimelineState("stopped", continuing: false)
        stopActiveTranscodeSession()
    }

    /// Fire-and-forget call to PMS to release the active transcode session.
    /// Without this, sessions accumulate on the server until its GC runs (~5 min),
    /// and Plex hits its concurrent-session limit after ~15 quick track advances.
    func stopActiveTranscodeSession() {
        guard let sessionID = currentSessionID,
              let server,
              let client else { return }
        logPlayback("transcode_stop", "session=\(sessionID)")
        Task.detached { [client, server, sessionID] in
            await client.universalTranscodeStop(server: server, sessionID: sessionID)
        }
    }

    /// Keeps the server's session (and other clients' "now playing") fresh on long tracks.
    func maybePingTimeline() {
        guard isPlaying, NetworkStatus.shared.isConnected,
              Date().timeIntervalSince(lastTimelineReport) >= timelinePingInterval else { return }
        reportTimelineState("playing")
    }

    func reportTimelineState(_ state: String, continuing: Bool = false) {
        guard let currentTrack, let client, let server else { return }
        lastTimelineReport = Date()
        let key = currentTrack.key ?? "/library/metadata/\(currentTrack.ratingKey)"
        let timeMs = Int(currentTime * 1000)
        let durationMs = Int(duration * 1000)
        let sessionID = currentSessionID
        Task {
            try? await client.reportTimeline(
                server: server,
                ratingKey: currentTrack.ratingKey,
                key: key,
                state: state,
                timeMs: timeMs,
                durationMs: durationMs,
                sessionID: sessionID,
                continuing: continuing
            )
        }
    }

    func maybeReportScrobble(force: Bool = false) {
        guard let currentTrack, let client, let server else { return }
        guard scrobbledTrackRatingKey != currentTrack.ratingKey else { return }

        let shouldScrobble: Bool
        if force {
            shouldScrobble = true
        } else if duration > 0 {
            shouldScrobble = (currentTime / duration) >= scrobbleThreshold
        } else {
            shouldScrobble = false
        }

        guard shouldScrobble else { return }
        scrobbledTrackRatingKey = currentTrack.ratingKey
        logPlayback("scrobble", "time=\(Int(currentTime)) duration=\(Int(duration))")
        let capturedServer = server
        let capturedRatingKey = currentTrack.ratingKey
        Task {
            do {
                try await client.reportScrobble(server: capturedServer, ratingKey: capturedRatingKey)
            } catch {
                // Unreachable server (e.g. offline playback): keep the play and retry later.
                await ScrobbleOutbox.shared.enqueue(ratingKey: capturedRatingKey, server: capturedServer)
            }
            await client.refreshItem(server: capturedServer, ratingKey: capturedRatingKey)
            NotificationCenter.default.post(name: .recentlyPlayedDidChange, object: nil)
        }
    }
}
