import SwiftUI

struct EditMetadataSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EditMetadataViewModel
    let onSaved: @MainActor (PlexMetadata) -> Void

    init(item: PlexMetadata, onSaved: @escaping @MainActor (PlexMetadata) -> Void) {
        _viewModel = State(initialValue: EditMetadataViewModel(item: item))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                MetadataFieldsSection(viewModel: viewModel)
            }
            .navigationTitle(viewModel.isTrack ? "Edit Track" : "Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button("Save", systemImage: "checkmark") { save() }
                            .disabled(!viewModel.hasChanges || !viewModel.isValid)
                    }
                }
            }
            .interactiveDismissDisabled(viewModel.isSaving)
            .alert("Unable to Save", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        Task {
            if let fresh = await viewModel.save(server: server, sectionId: sectionId, client: client) {
                onSaved(fresh)
                dismiss()
            }
        }
    }
}

#Preview {
    EditMetadataSheet(
        item: PlexMetadata(ratingKey: "1", title: "Test Song", type: "track"),
        onSaved: { _ in }
    )
}
