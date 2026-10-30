import SwiftUI

struct AutoMixReportView: View {
    // Built once when the menu item is tapped, so playback ticks re-rendering Now Playing
    // don't rebuild the form while typing.
    @Bindable var viewModel: AutoMixReportViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Songs") {
                    songRow("Previous", viewModel.previous)
                    songRow("Current", viewModel.current)
                }
                Section("Issue") {
                    Picker("Issue", selection: $viewModel.issue) {
                        ForEach(AutoMixIssueType.allCases) { issue in
                            Text(issue.rawValue).tag(issue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("Details") {
                    TextField("What did you hear?", text: $viewModel.details, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle("Report AutoMix Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.sendState == .sending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task { await viewModel.send() }
                        }
                        .disabled(!viewModel.canSend)
                    }
                }
            }
            .alert("Report Sent", isPresented: sentBinding) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thanks, this helps tune Auto Mix.")
            }
            .alert("Couldn't Send", isPresented: failedBinding) {
                Button("OK") { viewModel.sendState = .idle }
            } message: {
                if case .failed(let message) = viewModel.sendState { Text(message) }
            }
        }
    }

    private var sentBinding: Binding<Bool> {
        Binding(get: { viewModel.sendState == .sent }, set: { _ in })
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = viewModel.sendState { true } else { false } },
            set: { if !$0 { viewModel.sendState = .idle } }
        )
    }

    private func songRow(_ label: String, _ track: PlexMetadata?) -> some View {
        HStack(spacing: 12) {
            if let track {
                ArtworkView(thumbPath: track.parentThumb ?? track.thumb, size: 44, cornerRadius: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(track?.title ?? "None")
                    .lineLimit(1)
                if let track {
                    Text(track.artistDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

#Preview {
    AutoMixReportView(viewModel: AutoMixReportViewModel(player: AudioPlayerService()))
}
