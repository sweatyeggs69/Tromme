import SwiftUI

struct OfflineSettingsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage("autoDownloadMode") private var autoDownloadMode = AutoDownloadMode.defaultMode.rawValue
    @AppStorage("dynamicDownloadLimit") private var dynamicDownloadLimit = 5
    @AppStorage(DownloadQuality.storageKey) private var downloadQuality = DownloadQuality.original.rawValue

    @State private var plus = PlusStore.shared
    @State private var showPaywall = false

    private static let dynamicDownloadLimitOptions: [Int] = [5, 10, 20]

    var body: some View {
        Form {
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

                Toggle("Download Library", isOn: $autoDownloadEnabled)
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
            } footer: {
                Text(footerText)
            }

            Section {
                Picker("Max Bitrate", selection: $downloadQuality) {
                    ForEach(DownloadQuality.allCases, id: \.rawValue) { quality in
                        Text(quality.displayName).tag(quality.rawValue)
                    }
                }
                .disabled(!plus.isPlus)
                .overlay {
                    // A disabled control swallows taps, so catch them above it to offer the paywall.
                    if !plus.isPlus {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { showPaywall = true }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Max Bitrate, requires Tromme Plus")
                    }
                }
            } footer: {
                Text("Songs above the chosen bitrate are converted to AAC on your Plex server, which can make those downloads take longer. Other songs download as the original.")
            }
        }
        .navigationTitle("Offline")
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
        .onAppear {
            // "spaceSaver" was the earlier fixed 256 kbps setting.
            if downloadQuality == "spaceSaver" { downloadQuality = DownloadQuality.kbps256.rawValue }
        }
    }

    private var footerText: String {
        if autoDownloadEnabled {
            switch AutoDownloadMode(rawValue: autoDownloadMode) ?? .defaultMode {
            case .library:
                return "Downloads your entire library and any newly added tracks automatically."
            case .queue:
                return "Dynamically downloads songs from your play queue, advancing as you listen."
            }
        }
        return "Automatically download songs for offline playback."
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
}

#Preview {
    NavigationStack {
        OfflineSettingsView()
            .environment(DownloadManager())
            .environment(AudioPlayerService())
    }
}
