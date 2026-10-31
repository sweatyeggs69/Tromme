import SwiftUI

struct OfflineSettingsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage(DownloadQuality.storageKey) private var downloadQuality = DownloadQuality.original.rawValue

    @State private var plus = PlusStore.shared
    @State private var showPaywall = false

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
                        startLibraryDownload()
                    }
                Picker("Max Bitrate", selection: displayedQuality) {
                    ForEach(DownloadQuality.allCases, id: \.rawValue) { quality in
                        Text(quality.displayName).tag(quality.rawValue)
                    }
                }
                .disabled(!plus.isPlus)
                .overlay {
                    if !plus.isPlus {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { showPaywall = true }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Max Bitrate, requires Tromme +")
                    }
                }
            } footer: {
                Text("Download Library keeps every song on this device for offline playback. Songs above the chosen bitrate are converted to AAC on your Plex server, which can make those downloads take longer. Other songs download as the original.")
            }
        }
        .navigationTitle("Offline")
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
        .onAppear {
            if downloadQuality == "spaceSaver" { downloadQuality = DownloadQuality.kbps256.rawValue }
        }
    }

    private var displayedQuality: Binding<String> {
        Binding(
            get: { plus.isPlus ? downloadQuality : DownloadQuality.original.rawValue },
            set: { downloadQuality = $0 }
        )
    }

    private func startLibraryDownload() {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        Task {
            if let tracks = try? await client.cachedTracks(server: server, sectionId: sectionId) {
                downloadManager.resumeAutoDownload(tracks: tracks, server: server, client: client)
            }
        }
    }
}

#Preview {
    NavigationStack {
        OfflineSettingsView()
            .environment(DownloadManager())
    }
}
