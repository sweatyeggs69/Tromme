import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("hasRequestedAppReview") private var hasRequestedAppReview = false
    @State private var showReviewPrompt = false
    @State private var sections: [LibrarySection] = []
    @State private var plus = PlusStore.shared
    @State private var showPaywall = false
    @State private var showManageSubscription = false

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
                if plus.isGrandfathered {
                    Button("Support Tromme") { showPaywall = true }
                } else if plus.isPlus {
                    Button("Manage Tromme Plus") { showManageSubscription = true }
                } else {
                    Button("Get Tromme Plus") { showPaywall = true }
                }
            } footer: {
                if plus.isGrandfathered {
                    Text("You have Tromme Plus for free as a Premium Icon Pack owner.")
                } else if !plus.isPlus {
                    Text("Get access to the premium icons, animated artwork and support ongoing development of Tromme.")
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
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
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
