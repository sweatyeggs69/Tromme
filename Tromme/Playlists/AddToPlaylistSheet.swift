import SwiftUI

struct AddToPlaylistSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    let itemRatingKeys: [String]
    let onComplete: (Int) -> Void

    @State private var playlists: [PlexPlaylist] = []
    @State private var selectedPlaylistIDs = Set<PlexPlaylist.ID>()
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showingCreateAlert = false
    @State private var newPlaylistTitle = ""

    init(itemRatingKeys: [String], onComplete: @escaping (Int) -> Void = { _ in }) {
        self.itemRatingKeys = Self.orderedUnique(keys: itemRatingKeys)
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading playlists…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("No non-smart music playlists were found on this server.")
                    )
                } else {
                    List(playlists, selection: $selectedPlaylistIDs) { playlist in
                        HStack(spacing: 12) {
                            ArtworkView(thumbPath: playlist.thumb ?? playlist.composite, size: 44, cornerRadius: 6)
                            Text(playlist.title)
                                .lineLimit(1)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create Playlist")
                    .disabled(isSubmitting || isCreating || isLoading || itemRatingKeys.isEmpty)
                    .alert("Create Playlist", isPresented: $showingCreateAlert) {
                        TextField("Playlist name", text: $newPlaylistTitle)
                        Button("Cancel", role: .cancel) {
                            newPlaylistTitle = ""
                        }
                        Button("Create") {
                            Task { await createPlaylist() }
                        }
                        .disabled(newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    } message: {
                        Text("Enter a name for the new playlist.")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(addButtonTitle) {
                        Task { await addToSelectedPlaylists() }
                    }
                    .disabled(selectedPlaylistIDs.isEmpty || isSubmitting || isCreating || itemRatingKeys.isEmpty)
                }
            }
        }
        .task { await loadPlaylists() }
        .alert("Unable to Add", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var addButtonTitle: String {
        selectedPlaylistIDs.isEmpty ? "Add" : "Add (\(selectedPlaylistIDs.count))"
    }

    @MainActor
    private func loadPlaylists() async {
        guard let server = serverConnection.currentServer else {
            playlists = []
            isLoading = false
            return
        }

        do {
            let all = try await client.cachedPlaylists(server: server)
            playlists = all
                .filter { $0.isMusicPlaylist && $0.smart != true }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            playlists = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func addToSelectedPlaylists() async {
        guard !isSubmitting else { return }
        guard let server = serverConnection.currentServer else { return }
        let targets = playlists.filter { selectedPlaylistIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        isSubmitting = true
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for playlist in targets {
                    group.addTask {
                        try await client.addItemsToPlaylist(
                            server: server,
                            playlistId: playlist.ratingKey,
                            itemRatingKeys: itemRatingKeys
                        )
                    }
                }
                try await group.waitForAll()
            }

            await LibraryCache.shared.remove(forKey: CacheKey.playlists(serverId: server.machineIdentifier))
            for playlist in targets {
                await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: playlist.ratingKey))
                if let key = playlist.key {
                    await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: key))
                }
            }

            onComplete(targets.count)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }

    @MainActor
    private func createPlaylist() async {
        let trimmedTitle = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard let server = serverConnection.currentServer else { return }
        guard !isCreating else { return }

        isCreating = true
        do {
            let created = try await client.createPlaylist(
                server: server,
                title: trimmedTitle,
                playlistType: "audio",
                itemRatingKeys: itemRatingKeys
            )
            playlists.append(created)
            playlists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            selectedPlaylistIDs.insert(created.id)
            newPlaylistTitle = ""
            await LibraryCache.shared.remove(forKey: CacheKey.playlists(serverId: server.machineIdentifier))
            await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: created.ratingKey))
            if let key = created.key {
                await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: key))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }

    private static func orderedUnique(keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys where !key.isEmpty {
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }
}

#if DEBUG
#Preview {
    AddToPlaylistSheet(itemRatingKeys: ["12345"])
}
#endif
