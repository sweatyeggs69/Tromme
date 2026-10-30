import SwiftUI

struct EditTagsSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EditTagsViewModel
    let onSaved: @MainActor (PlexMetadata) -> Void

    init(item: PlexMetadata, onSaved: @escaping @MainActor (PlexMetadata) -> Void) {
        _viewModel = State(initialValue: EditTagsViewModel(item: item))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                TagsSection(viewModel: viewModel)
            }
            .navigationTitle("Edit Artist")
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
                            .disabled(!viewModel.hasChanges)
                    }
                }
            }
            .task { await loadSuggestions() }
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

    private func loadSuggestions() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        await viewModel.loadSuggestions(server: server, sectionId: sectionId, client: client)
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
    EditTagsSheet(
        item: PlexMetadata(ratingKey: "1", title: "Test Album", type: "album"),
        onSaved: { _ in }
    )
}
