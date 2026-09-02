import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("hasRequestedAppReview") private var hasRequestedAppReview = false
    @State private var showReviewPrompt = false
    @State private var showSignOutConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var isRefreshing = false
    @State private var sections: [LibrarySection] = []
    var onSignOut: () -> Void

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
                Button {
                    Task { await refreshLibrary() }
                } label: {
                    HStack {
                        Text("Refresh Library")
                        Spacer()
                        if isRefreshing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshing)

                Button("Clear Cache") {
                    showClearCacheConfirmation = true
                }
            } header: {
                Text("Library")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
            }
        }
        .navigationTitle("Settings")
        .task { await loadSections() }
        .alert("Sign Out", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                onSignOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to access your music.")
        }
        .alert("Clear Cache", isPresented: $showClearCacheConfirmation) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await LibraryCache.shared.clearAll()
                    await ImageCache.shared.clearAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all cached data. It will be re-downloaded automatically.")
        }
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

    private func refreshLibrary() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        isRefreshing = true
        await LibraryCache.shared.clearAll()
        await client.warmCache(server: server, sectionId: sectionId)
        isRefreshing = false
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
        SettingsView { }
            .environment(DownloadManager())
            .environment(AudioPlayerService())
    }
}
