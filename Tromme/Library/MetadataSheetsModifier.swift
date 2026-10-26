import SwiftUI

/// Presents the album edit and combined track sheets for a `MetadataSheetRequest`.
private struct MetadataSheetsModifier: ViewModifier {
    @Binding var request: MetadataSheetRequest?
    let onSaved: @MainActor (PlexMetadata) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            switch request {
            case .edit(let item):
                EditMetadataSheet(item: item, onSaved: onSaved)
            case .trackInfo(let track):
                TrackInfoSheet(track: track, onSaved: onSaved)
            }
        }
    }
}

extension View {
    /// `onSaved` receives the item re-read from the server after an edit.
    func metadataSheets(
        request: Binding<MetadataSheetRequest?>,
        onSaved: @escaping @MainActor (PlexMetadata) -> Void
    ) -> some View {
        modifier(MetadataSheetsModifier(request: request, onSaved: onSaved))
    }
}
