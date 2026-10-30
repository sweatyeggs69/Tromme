import SwiftUI
import EventKit
import EventKitUI

struct ConcertCalendarEditor: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let concert: ConcertEvent
    let artistName: String

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = artistName
        event.location = [concert.venue, concert.addressText].filter { !$0.isEmpty }.joined(separator: ", ")
        event.url = concert.url
        if let start = concert.instant {
            event.startDate = start
            event.endDate = start.addingTimeInterval(3 * 3600)
        } else {
            var gmt = Calendar(identifier: .gregorian)
            gmt.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            let parts = gmt.dateComponents([.year, .month, .day, .hour, .minute], from: concert.date)
            let start = Calendar.current.date(from: parts) ?? concert.date
            event.startDate = start
            event.endDate = concert.hasTime ? start.addingTimeInterval(3 * 3600) : start
            event.isAllDay = !concert.hasTime
        }

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
