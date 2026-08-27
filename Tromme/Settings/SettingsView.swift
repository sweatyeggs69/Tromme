import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AudioPlayerService.self) private var player

    @AppStorage("disableCellularTranscoding") private var disableCellularTranscoding = true
    @AppStorage("cellularTranscodeBitrateKbps") private var cellularTranscodeBitrateKbps = 320
    @AppStorage("playbackBadgeMode") private var playbackBadgeMode = "codecBitrate"
    @AppStorage("soundCheckEnabled") private var soundCheckEnabled = false
    @AppStorage("soundCheckGainSource") private var soundCheckGainSource = "track"
    @AppStorage("hasRequestedAppReview") private var hasRequestedAppReview = false
    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "immersive"
    @AppStorage("autoDownloadMode") private var autoDownloadMode = AutoDownloadMode.defaultMode.rawValue
    @AppStorage("dynamicDownloadLimit") private var dynamicDownloadLimit = 5
    @AppStorage("downloadFormat") private var downloadFormat = DownloadFormat.defaultFormat.rawValue
    @State private var showReviewPrompt = false
    @State private var showSignOutConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var isRefreshing = false
    @State private var sections: [LibrarySection] = []
    var onSignOut: () -> Void

    private static let cellularTranscodeBitrateOptions: [Int] = [192, 256, 320]
    private static let dynamicDownloadLimitOptions: [Int] = [5, 10, 20]

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
                Toggle("Featured Section", isOn: $showFeaturedSection)
                    .tint(.green)
                if showFeaturedSection {
                    Picker("Size", selection: $featuredBannerSize) {
                        Text("Small").tag("small")
                        Text("Large").tag("large")
                        Text("Immersive").tag("immersive")
                    }
                }
            } header: {
                Text("Home")
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
                Picker("Show Codec/Bitrate", selection: $playbackBadgeMode) {
                    Text("Off").tag("off")
                    Text("Codec").tag("codec")
                    Text("Codec + Bitrate").tag("codecBitrate")
                }
                Toggle("Sound Check", isOn: $soundCheckEnabled)
                    .tint(.green)
                if soundCheckEnabled {
                    Picker("Gain Source", selection: $soundCheckGainSource) {
                        Text("Track").tag("track")
                        Text("Album").tag("album")
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text(playbackFooterText)
            }

            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("Downloads") {
                        let remaining = downloadManager.pendingDownloadCount
                        if remaining > 0 {
                            Text("\(remaining) remaining")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(downloadManager.storageDescription)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Download Format", selection: $downloadFormat) {
                    ForEach(DownloadFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }

                Toggle("Auto-Download", isOn: $autoDownloadEnabled)
                    .tint(.green)
                    .onChange(of: autoDownloadEnabled) { _, enabled in
                        guard enabled else { return }
                        startAutoDownloadForCurrentMode()
                    }
                if autoDownloadEnabled {
                    Picker("Mode", selection: $autoDownloadMode) {
                        ForEach(AutoDownloadMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: autoDownloadMode) { _, _ in
                        startAutoDownloadForCurrentMode()
                    }
                    if autoDownloadMode == AutoDownloadMode.queue.rawValue {
                        Picker("Song Limit", selection: $dynamicDownloadLimit) {
                            ForEach(Self.dynamicDownloadLimitOptions, id: \.self) { limit in
                                Text("\(limit) songs").tag(limit)
                            }
                        }
                        .onChange(of: dynamicDownloadLimit) { _, _ in
                            player.syncDynamicQueueDownloads()
                        }
                    }
                }
            } header: {
                Text("Offline")
            } footer: {
                Text(offlineFooterText)
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

    private var offlineFooterText: String {
        var text: String
        if autoDownloadEnabled {
            switch AutoDownloadMode(rawValue: autoDownloadMode) ?? .defaultMode {
            case .library:
                text = "Downloads your entire library and any newly added tracks automatically."
            case .queue:
                text = "Dynamically downloads songs from your play queue, advancing as you listen."
            }
        } else {
            text = "Automatically download songs for offline playback."
        }
        return text
    }

    private func startAutoDownloadForCurrentMode() {
        switch AutoDownloadMode(rawValue: autoDownloadMode) ?? .defaultMode {
        case .library:
            guard let server = serverConnection.currentServer,
                  let sectionId = serverConnection.currentLibrarySectionId else { return }
            Task {
                if let tracks = try? await client.cachedTracks(server: server, sectionId: sectionId) {
                    downloadManager.resumeAutoDownload(tracks: tracks, server: server, client: client)
                }
            }
        case .queue:
            player.syncDynamicQueueDownloads()
        }
    }

    private var playbackFooterText: String {
        if supportsCellularSettings {
            return "Enable transcoding to use less data on mobile networks. Sound Check can use track or album gain to keep volume consistent."
        }
        return "Sound Check keeps song volume more consistent using track or album gain."
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
