import SwiftUI

struct ServerSettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var showSignOutConfirmation = false
    @State private var sections: [LibrarySection] = []
    var onSignOut: () -> Void

    var body: some View {
        Form {
            Section("Connected Server") {
                if let server = serverConnection.currentServer {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("Connection", value: connectionLabel(for: server))
                }

                if sections.count > 1 {
                    Picker("Library", selection: libraryBinding) {
                        ForEach(sections) { section in
                            Text(section.title).tag(section.key)
                        }
                    }
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
            }
        }
        .navigationTitle("Server")
        .task { await loadSections() }
        .confirmationDialog("Sign Out", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                onSignOut()
            }
        } message: {
            Text("You'll need to sign in again to access your music.")
        }
    }

    private var libraryBinding: Binding<String> {
        Binding(
            get: { serverConnection.currentLibrarySectionId ?? "" },
            set: { serverConnection.selectLibrary($0) }
        )
    }

    private func loadSections() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            sections = try await client.cachedLibrarySections(server: server)
        } catch {}
    }

    private func connectionLabel(for server: PlexServer) -> String {
        if let active = server.connections.first(where: { $0.uri == server.uri }) {
            if active.relay == true { return "Relay" }
            if active.local == true { return "Local" }
            return "Remote"
        }
        return "Unknown"
    }
}

#Preview {
    NavigationStack {
        ServerSettingsView { }
    }
}
