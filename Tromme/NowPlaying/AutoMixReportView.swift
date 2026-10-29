import SwiftUI

struct AutoMixReportView: View {
    @State private var viewModel: AutoMixReportViewModel
    @Environment(\.dismiss) private var dismiss

    init(player: AudioPlayerService) {
        _viewModel = State(initialValue: AutoMixReportViewModel(player: player))
    }

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
                    ShareLink(item: viewModel.reportText, subject: Text(viewModel.subject)) {
                        Text("Send")
                    }
                    .disabled(!viewModel.canSend)
                }
            }
        }
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
    AutoMixReportView(player: AudioPlayerService())
}
