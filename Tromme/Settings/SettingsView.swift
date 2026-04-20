import SwiftUI

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("magicMixStyleMatch") private var magicMixStyleMatch = 2
    @AppStorage("disableCellularTranscoding") private var disableCellularTranscoding = true
    @AppStorage("cellularTranscodeBitrateKbps") private var cellularTranscodeBitrateKbps = 320
    @AppStorage("soundCheckEnabled") private var soundCheckEnabled = false
    @State private var showSignOutConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var isRefreshing = false
    @State private var sections: [LibrarySection] = []
    var onSignOut: () -> Void

    private static let cellularTranscodeBitrateOptions: [Int] = [192, 256, 320]

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

            Section {
                Toggle("Cellular Transcoding", isOn: cellularTranscodingBinding)
                    .tint(.green)
                Picker("Cellular Bitrate", selection: $cellularTranscodeBitrateKbps) {
                    ForEach(Self.cellularTranscodeBitrateOptions, id: \.self) { bitrate in
                        Text("\(bitrate) kbps").tag(bitrate)
                    }
                }
                .disabled(!cellularTranscodingBinding.wrappedValue)
                Toggle("Sound Check", isOn: $soundCheckEnabled)
                    .tint(.green)
            } header: {
                Text("Playback")
            } footer: {
                Text("When enabled audio streams over cellular are delivered in AAC format and at the desired bitrate. FLAC will always transcode to a compatible container (ALAC on WiFi, AAC on cellular). Sound Check normalizes volume across tracks using ReplayGain data to target −14 LUFS.")
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

    private func loadSections() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            sections = try await client.cachedLibrarySections(server: server)
        } catch {}
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
