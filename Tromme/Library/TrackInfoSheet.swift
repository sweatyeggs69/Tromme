import SwiftUI

struct TrackInfoSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: TrackInfoViewModel
    @State private var editModel: EditMetadataViewModel
    let isEditable: Bool
    let onSaved: @MainActor (PlexMetadata) -> Void

    init(track: PlexMetadata, isEditable: Bool = true, onSaved: @escaping @MainActor (PlexMetadata) -> Void) {
        _viewModel = State(initialValue: TrackInfoViewModel(track: track))
        _editModel = State(initialValue: EditMetadataViewModel(item: track))
        self.isEditable = isEditable
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                if isEditable {
                    MetadataFieldsSection(viewModel: editModel)
                        .disabled(serverConnection.currentServer == nil || editModel.isSaving)

                    Section {
                        row("Duration", viewModel.track.durationFormatted)
                    }
                }

                Section("Media") {
                    row("Codec", (viewModel.audioStream?.codec ?? viewModel.media?.audioCodec)?.uppercased())
                    row("Bit Rate", (viewModel.audioStream?.bitrate ?? viewModel.media?.bitrate).map { "\($0) kbps" })
                    row("Sample Rate", viewModel.audioStream?.samplingRate.map { String(format: "%.1f kHz", Double($0) / 1000) })
                    row("Bit Depth", viewModel.audioStream?.bitDepth.map { "\($0)-bit" })
                    row("Channels", (viewModel.audioStream?.channels ?? viewModel.media?.audioChannels).map(String.init))
                    row("File Size", viewModel.part?.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) })
                }

                if let download = viewModel.download {
                    Section("Download") {
                        row("Format", download.fileExtension.uppercased())
                        row("Bit Rate", download.averageBitrateKbps.map { "\($0) kbps" })
                        row("File Size", ByteCountFormatter.string(fromByteCount: download.fileSize, countStyle: .file))
                        row("Downloaded", download.downloadedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                if let duration = viewModel.track.duration, duration > 1000 {
                    TrackMarkersSection(ratingKey: viewModel.track.ratingKey, duration: Double(duration) / 1000)
                }

                if let file = viewModel.part?.file {
                    Section("File Path") {
                        Text(file)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.media == nil {
                    ProgressView()
                }
            }
            .navigationTitle("Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editModel.hasChanges {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editModel.isSaving {
                        ProgressView()
                    } else if editModel.hasChanges {
                        Button("Save", systemImage: "checkmark") { save() }
                            .disabled(!editModel.isValid)
                    } else {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(editModel.isSaving)
            .alert("Unable to Save", isPresented: .init(
                get: { editModel.errorMessage != nil },
                set: { if !$0 { editModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editModel.errorMessage ?? "")
            }
            .task {
                await viewModel.load(server: serverConnection.currentServer, client: client)
            }
        }
    }

    private func save() {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        Task {
            if let fresh = await editModel.save(server: server, sectionId: sectionId, client: client) {
                onSaved(fresh)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }
}

#Preview {
    TrackInfoSheet(track: PlexMetadata(ratingKey: "1", title: "Test Song", type: "track"), onSaved: { _ in })
}
