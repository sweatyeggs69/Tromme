import SwiftUI

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("magicMixStyleMatch") private var magicMixStyleMatch = 2
    @AppStorage("disableCellularTranscoding") private var disableCellularTranscoding = true
    @AppStorage("cellularTranscodeBitrateKbps") private var cellularTranscodeBitrateKbps = 320
    @AppStorage("soundCheckEnabled") private var soundCheckEnabled = false
    @AppStorage("miniLyricsModeEnabled") private var miniLyricsModeEnabled = false
    @State private var showSignOutConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var isRefreshing = false
    @State private var sections: [LibrarySection] = []
    var onSignOut: () -> Void

    private static let cellularTranscodeBitrateOptions: [Int] = [192, 256, 320]

    var body: some View {
        Form {
            Section {
                Toggle("Mini Mode", isOn: $miniLyricsModeEnabled)
                    .tint(.green)
            } header: {
                Text("Lyrics")
            }
            
            Section {
                Picker("Style Match", selection: $magicMixStyleMatch) {
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
            } header: {
                Text("Magic Mix")
            } footer: {
                Text("How many style tags should match for Magic Mix. If a track or album has fewer style tags than this value, Magic Mix automatically uses the available tag count instead.")
            }

            Section {
                if supportsCellularSettings {
                    Toggle("Cellular Transcoding", isOn: cellularTranscodingBinding)
                        .tint(.green)
                    if cellularTranscodingBinding.wrappedValue {
                        Picker("Bitrate", selection: $cellularTranscodeBitrateKbps) {
                            ForEach(Self.cellularTranscodeBitrateOptions, id: \.self) { bitrate in
                                Text("\(bitrate) kbps").tag(bitrate)
                            }
                        }
                    }
                }
                Toggle("Sound Check", isOn: $soundCheckEnabled)
                    .tint(.green)
            } header: {
                Text("Playback")
            } footer: {
                Text(playbackFooterText)
            }

            Section {
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
            } header: {
                Text("Server")
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
    }

    private var libraryBinding: Binding<String> {
        Binding(
            get: { serverConnection.currentLibrarySectionId ?? "" },
            set: { serverConnection.selectLibrary($0, client: client) }
        )
    }

    private var cellularTranscodingBinding: Binding<Bool> {
        Binding(
            get: { !disableCellularTranscoding },
            set: { disableCellularTranscoding = !$0 }
        )
    }

    private var supportsCellularSettings: Bool {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return true
        }
        return NetworkStatus.shared.isCellular || NetworkStatus.shared.interfaceType == .cellular
    }

    private var playbackFooterText: String {
        if supportsCellularSettings {
            return "Enable transcoding to use less data on mobile networks. Sound Check adjusts track gain to keep volume consistent."
        }
        return "Sound Check keeps song volume more consistent."
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
