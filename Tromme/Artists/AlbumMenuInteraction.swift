import SwiftUI
import UIKit

struct AlbumMenuAction {
    let title: String
    let systemImage: String
    let handler: () -> Void
}

struct AlbumMenuInteraction<Preview: View>: UIViewRepresentable {
    let actions: [AlbumMenuAction]
    let preview: Preview
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onTap = onTap
        context.coordinator.makePreview = {
            let host = UIHostingController(rootView: preview)
            host.view.backgroundColor = .clear
            host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 232, height: .greatestFiniteMagnitude))
            return host
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var actions: [AlbumMenuAction] = []
        var onTap: () -> Void = {}
        var makePreview: () -> UIViewController = { UIViewController() }

        @objc func tapped() { onTap() }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let actions = actions
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: { [makePreview] in makePreview() },
                actionProvider: { _ in
                    UIMenu(children: actions.map { action in
                        UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in action.handler() }
                    })
                }
            )
        }
    }
}
