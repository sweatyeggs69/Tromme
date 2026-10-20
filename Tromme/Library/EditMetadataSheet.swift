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
                Section {
                    LabeledContent("Title") {
                        TextField("Title", text: $viewModel.title)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Artist") {
                        TextField("Artist", text: $viewModel.artist)
                            .multilineTextAlignment(.trailing)
                    }
                    if viewModel.isTrack {
                        LabeledContent("Album") {
                            TextField("Album", text: $viewModel.album)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Track Number") {
                            TextField("Number", text: $viewModel.trackNumberText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Year") {
                        TextField("Year", text: $viewModel.yearText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text(viewModel.isTrack
                         ? "Changing the album or artist moves this track. A name that already exists merges into it."
                         : "Renaming to an existing album or artist merges into it.")
                }
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
