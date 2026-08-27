import SwiftUI

struct OfflineSettingsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage("autoDownloadMode") private var autoDownloadMode = AutoDownloadMode.defaultMode.rawValue
    @AppStorage("dynamicDownloadLimit") private var dynamicDownloadLimit = 5
    @AppStorage("downloadFormat") private var downloadFormat = DownloadFormat.defaultFormat.rawValue

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
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle("Offline")
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
