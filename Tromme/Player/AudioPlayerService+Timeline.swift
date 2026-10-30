import AVFoundation
import MediaPlayer
import Network
import Observation

extension AudioPlayerService {
    // MARK: - Timeline Reporting

    func reportStoppedForAppTermination() {
        guard currentTrack != nil else { return }
        reportTimelineState("stopped", continuing: false)
    }

    /// The spec asks for a timeline report every 10 s on LAN/WAN and every 20 s over
    /// cellular when the play state hasn't changed. PMS builds play history and the
    /// played state from these reports, so the app sends no separate scrobble.
    func maybePingTimeline() {
        let interval: TimeInterval = NetworkStatus.shared.isCellular ? 20 : 10
        guard isPlaying, NetworkStatus.shared.isConnected,
              Date().timeIntervalSince(lastTimelineReport) >= interval else { return }
        reportTimelineState("playing")
    }

    func reportTimelineState(_ state: String, continuing: Bool = false) {
        guard let currentTrack, let client, let server else { return }
        lastTimelineReport = Date()
        let ratingKey = currentTrack.ratingKey
        let key = currentTrack.key ?? "/library/metadata/\(ratingKey)"
        let timeMs = Int(currentTime * 1000)
        let durationMs = Int(duration * 1000)
        let sessionID = currentSessionID
        Task {
            do {
                try await client.reportTimeline(
                    server: server,
                    ratingKey: ratingKey,
                    key: key,
                    state: state,
                    timeMs: timeMs,
                    durationMs: durationMs,
                    sessionID: sessionID,
                    continuing: continuing
                )
            } catch {
                // Server unreachable (e.g. offline playback): keep the finished play and
                // replay it later as an offline timeline, as the spec describes for sync clients.
                if state == "stopped" {
                    await TimelineOutbox.shared.enqueue(
                        ratingKey: ratingKey, key: key, timeMs: timeMs, durationMs: durationMs, server: server
                    )
                }
                return
            }
            guard state == "stopped" else { return }
            await client.refreshItem(server: server, ratingKey: ratingKey)
            NotificationCenter.default.post(name: .recentlyPlayedDidChange, object: nil)
        }
    }
}
