import SwiftUI

private struct MetadataSheetsModifier: ViewModifier {
    @Binding var request: MetadataSheetRequest?
    let isTrackEditable: Bool
    let onSaved: @MainActor (PlexMetadata) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            switch request {
            case .edit(let item):
                EditMetadataSheet(item: item, onSaved: onSaved)
            case .trackInfo(let track):
                TrackInfoSheet(track: track, isEditable: isTrackEditable, onSaved: onSaved)
            }
        }
    }
}

extension View {
    func metadataSheets(
        request: Binding<MetadataSheetRequest?>,
        isTrackEditable: Bool = true,
        onSaved: @escaping @MainActor (PlexMetadata) -> Void
    ) -> some View {
        modifier(MetadataSheetsModifier(request: request, isTrackEditable: isTrackEditable, onSaved: onSaved))
    }
}
