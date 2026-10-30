#if DEBUG
import Foundation

enum AutoMixIssueType: String, CaseIterable, Identifiable {
    case startedTooEarly = "Mix started too early"
    case startedTooLate = "Mix started too late"
    case tooShort = "Mix was too short"
    case tooLong = "Mix was too long"
    case cutOffVocals = "Cut off the vocals"
    case vocalsClashed = "Vocals overlapped"
    case badFilter = "Filter sound was off"
    case shouldNotMix = "These songs should not mix"
    case shouldHaveMixed = "These songs should have mixed"
    case glitch = "Glitch, gap or silence"
    case other = "Other"

    var id: String { rawValue }
}
#endif
