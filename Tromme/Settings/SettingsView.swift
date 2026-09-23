import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("hasRequestedAppReview") private var hasRequestedAppReview = false
    @State private var showReviewPrompt = false
    @State private var sections: [LibrarySection] = []

    var body: some View {
        Form {
            if !hasRequestedAppReview {
                Section {
                    Button("Leave a Review") {
                        showReviewPrompt = true
                    }
                }
            }

            Section {
                NavigationLink("Interface") { HomeSettingsView() }
                NavigationLink("Playback") { PlaybackSettingsView() }
                NavigationLink("Offline") { OfflineSettingsView() }
                NavigationLink("App Icon") { AppIconPickerView() }
            }

            if let server = serverConnection.currentServer {
                Section {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("Connection", value: connectionLabel(for: server))

                    Button("Change Server") {
                        serverConnection.disconnect()
                    }

                    if sections.count > 1 {
                        Picker("Library", selection: libraryBinding) {
                            ForEach(sections) { section in
                                Text(section.title).tag(section.key)
                            }
                        }
                    }
                } header: {
                    Text("Server")
                }
            }

            Section {
                VStack(spacing: 4) {
                    Text("Tromme")
                        .font(.footnote.weight(.medium))
                    Text(appVersionString)
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Settings")
        .task { await loadSections() }
        .alert("Leave a Review?", isPresented: $showReviewPrompt) {
            Button("No Thanks", role: .cancel) {
                hasRequestedAppReview = true
            }
            Button("Leave Review") {
                requestAppReviewIfNeeded()
            }
        } message: {
            Text("Thanks for using Tromme! If you like it, let us know what you think.")
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(version)"
    }

    private var libraryBinding: Binding<String> {
        Binding(
            get: { serverConnection.currentLibrarySectionId ?? "" },
            set: { serverConnection.selectLibrary($0, client: client) }
        )
    }

    private func connectionLabel(for server: PlexServer) -> String {
        if let active = server.connections.first(where: { $0.uri == server.uri }) {
            if active.relay == true { return "Relay" }
            if active.local == true { return "Local" }
            return "Remote"
        }
        return "Unknown"
    }

    private func loadSections() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            sections = try await client.cachedLibrarySections(server: server).filter(\.isMusicLibrary)
        } catch {
            #if DEBUG
            print("[SettingsView] Failed to load library sections: \(error.localizedDescription)")
            #endif
        }
    }

    private func requestAppReviewIfNeeded() {
        guard !hasRequestedAppReview else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        AppStore.requestReview(in: scene)
        hasRequestedAppReview = true
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(DownloadManager())
            .environment(AudioPlayerService())
    }
}
