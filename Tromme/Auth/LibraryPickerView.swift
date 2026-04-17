import SwiftUI

struct LibraryPickerView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    var onLibrarySelected: () -> Void

    @State private var sections: [LibrarySection] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading libraries...")
                } else if let error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await loadSections() } }
                    }
                } else {
                    List(sections) { section in
                        Button {
                            serverConnection.selectLibrary(section.key, client: client)
                            onLibrarySelected()
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.orange)
                                    .font(.title2)

                                VStack(alignment: .leading) {
                                    Text(section.title)
                                        .font(.headline)
                                    if let scannedAt = section.scannedAt {
                                        Text("Last scanned: \(Date(timeIntervalSince1970: TimeInterval(scannedAt)).formatted(.relative(presentation: .named)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Music Libraries")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left") {
                        serverConnection.disconnect()
                    }
                    .tint(.primary)
                }
            }
        }
        .task { await loadSections() }
    }

    private func loadSections() async {
        guard let server = serverConnection.currentServer else { return }
        isLoading = true
        error = nil
        do {
            sections = try await client.cachedLibrarySections(server: server).filter(\.isMusicLibrary)
            if sections.count == 1, let first = sections.first {
                serverConnection.selectLibrary(first.key, client: client)
                onLibrarySelected()
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    LibraryPickerView { }
}
