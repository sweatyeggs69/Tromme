import Foundation
import UIKit
import Observation

@Observable @MainActor
final class AutoMixReportViewModel {
    let previous: PlexMetadata?
    let current: PlexMetadata?
    private let record: AutoMixRecord?

    var issue: AutoMixIssueType = .startedTooEarly
    var details = ""

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

    var canSend: Bool { previous != nil && current != nil }

    var subject: String { "Tromme Auto Mix report" }

    /// The report as plain text, with the mix plan values so a bad mix can be reproduced.
    var reportText: String {
        func describe(_ track: PlexMetadata?) -> String {
            guard let track else { return "none" }
            return "\(track.title) by \(track.artistDisplayName) [\(track.ratingKey)]"
        }
        var lines = [
            "Issue: \(issue.rawValue)",
            "Details: \(details.trimmingCharacters(in: .whitespacesAndNewlines))",
            "",
            "Previous: \(describe(previous))",
            "Current: \(describe(current))",
            "Result: \(record?.outcome ?? "no mix recorded for this pair")"
        ]
        for (key, value) in (record?.values ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        let info = Bundle.main.infoDictionary
        lines.append("")
        lines.append("Tromme \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        lines.append("Plus: \(PlusStore.cachedIsPlus)")
        return lines.joined(separator: "\n")
    }
}
