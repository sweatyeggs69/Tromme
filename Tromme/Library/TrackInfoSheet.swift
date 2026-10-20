import SwiftUI

struct TrackInfoSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: TrackInfoViewModel

    init(track: PlexMetadata) {
        _viewModel = State(initialValue: TrackInfoViewModel(track: track))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Track") {
                    row("Title", viewModel.track.title)
                    row("Artist", viewModel.track.artistName)
                    row("Album", viewModel.track.albumName)
                    row("Track Number", viewModel.track.index.map(String.init))
                    row("Year", viewModel.track.year.map(String.init))
                    row("Duration", viewModel.track.durationFormatted)
                }

                Section("Media") {
                    row("Codec", (viewModel.audioStream?.codec ?? viewModel.media?.audioCodec)?.uppercased())
                    row("Bit Rate", (viewModel.audioStream?.bitrate ?? viewModel.media?.bitrate).map { "\($0) kbps" })
                    row("Sample Rate", viewModel.audioStream?.samplingRate.map { String(format: "%.1f kHz", Double($0) / 1000) })
                    row("Bit Depth", viewModel.audioStream?.bitDepth.map { "\($0)-bit" })
                    row("Channels", (viewModel.audioStream?.channels ?? viewModel.media?.audioChannels).map(String.init))
                    row("File Size", viewModel.part?.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) })
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
            .navigationTitle("Track Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task {
                await viewModel.load(server: serverConnection.currentServer, client: client)
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
    TrackInfoSheet(track: PlexMetadata(ratingKey: "1", title: "Test Song", type: "track"))
}
