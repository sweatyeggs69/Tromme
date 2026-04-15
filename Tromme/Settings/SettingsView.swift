import SwiftUI

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("magicMixStyleMatch") private var magicMixStyleMatch = 2
    @State private var showSignOutConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var sections: [LibrarySection] = []
    var onSignOut: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Style Match", selection: $magicMixStyleMatch) {
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
            } header: {
                Text("Magic Mix")
            } footer: {
                Text("The number of style tags that must match between albums to be included in a mix. The higher the number the fewer amount tracks.")
            }
            
            Section("Server") {
                if let server = serverConnection.currentServer {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("Connection", value: connectionLabel(for: server))

                    Button("Change Server") {
                        serverConnection.disconnect()
                    }
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
                Button("Clear Cache") {
                    showClearCacheConfirmation = true
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
            }
        }
        .navigationTitle("Settings")
        .task { await loadSections() }
        .confirmationDialog("Sign Out", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                onSignOut()
            }
        } message: {
            Text("You'll need to sign in again to access your music.")
        }
        .confirmationDialog("Clear Cache", isPresented: $showClearCacheConfirmation, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await LibraryCache.shared.clearAll()
                    await ImageCache.shared.clearAll()
                }
            }
        } message: {
            Text("This will remove all cached data. It will be re-downloaded automatically.")
        }
    }

    private var libraryBinding: Binding<String> {
        Binding(
            get: { serverConnection.currentLibrarySectionId ?? "" },
            set: { serverConnection.selectLibrary($0, client: client) }
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
        SettingsView { }
    }
}
