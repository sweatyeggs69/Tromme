import Foundation
import UIKit
import Observation

@Observable @MainActor
final class AutoMixReportViewModel: Identifiable {
    enum SendState: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    let previous: PlexMetadata?
    let current: PlexMetadata?
    private let record: AutoMixRecord?

    var issue: AutoMixIssueType = .startedTooEarly
    var details = ""
    var sendState: SendState = .idle

    init(player: AudioPlayerService) {
        let current = player.currentTrack
        let record = player.autoMixRecords.last { $0.incoming.ratingKey == current?.ratingKey }
        self.current = current
        self.record = record
        if let record {
            previous = record.outgoing
        } else if player.currentIndex > 0, player.queue.indices.contains(player.currentIndex - 1) {
            previous = player.queue[player.currentIndex - 1]
        } else {
            previous = nil
        }
    }

    var canSend: Bool { previous != nil && current != nil && sendState != .sending }

    func send() async {
        guard let previous, let current else { return }
        sendState = .sending
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
        var values = record?.values ?? [:]
        if record == nil { values["recorded"] = "no" }
        let report = AutoMixReportSender.Report(
            installId: Self.installID,
            issue: issue.rawValue,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            previous: Self.song(previous),
            current: Self.song(current),
            result: record?.outcome ?? "no mix recorded for this pair",
            values: values,
            app: version,
            device: UIDevice.current.model,
            plus: PlusStore.cachedIsPlus
        )
        do {
            try await AutoMixReportSender.send(report)
            sendState = .sent
        } catch .rateLimited {
            sendState = .failed("You've sent a few reports recently. Try again later.")
        } catch {
            sendState = .failed("The report couldn't be sent. Check your connection and try again.")
        }
    }

    private static func song(_ track: PlexMetadata) -> AutoMixReportSender.Song {
        .init(key: track.ratingKey, title: track.title, artist: track.artistDisplayName)
    }

    private static var installID: String {
        let key = "autoMixReportInstallID"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
