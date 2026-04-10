import SwiftUI

struct SettingsView: View {
    @Environment(\.serverConnection) private var serverConnection

    @State private var showSignOutConfirmation = false
    var onSignOut: () -> Void

    var body: some View {
        Form {
            Section("Connected Server") {
                if let server = serverConnection.currentServer {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("URL", value: server.uri)
                    LabeledContent("Connection", value: connectionLabel(for: server))
                }
                if let sectionId = serverConnection.currentLibrarySectionId {
                    LabeledContent("Library", value: "Section \(sectionId)")
                }
            }

            Section("About") {
                LabeledContent("App", value: "Tromme")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign Out", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                onSignOut()
            }
        } message: {
            Text("You'll need to sign in again to access your music.")
        }
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
