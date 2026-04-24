import SwiftUI

struct ChangeAlbumArtworkSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    let albumRatingKey: String
    let onArtworkChanged: @MainActor () async -> Void

    @State private var artworkOptions: [PlexImageResource] = []
    @State private var isLoadingArtwork = true
    @State private var isApplyingArtwork = false
    @State private var applyingArtworkID: String?
    @State private var artworkErrorMessage: String?
    private let gridSpacing: CGFloat = 12
    private let horizontalInset: CGFloat = 16

    private var columns: [GridItem] {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return [
                GridItem(.flexible(), spacing: gridSpacing),
                GridItem(.flexible(), spacing: gridSpacing),
            ]
        } else {
            return [
                GridItem(.flexible(), spacing: gridSpacing),
            ]
        }
    }

    private var artworkTileSize: CGFloat {
        let columnCount = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        let totalSpacing = gridSpacing * CGFloat(max(columnCount - 1, 0))
        let available = UIScreen.main.bounds.width - (horizontalInset * 2) - totalSpacing
        return max(available / CGFloat(columnCount), 1)
    }

    private var sortedArtworkOptions: [PlexImageResource] {
        artworkOptions.sorted { lhs, rhs in
            if (lhs.selected ?? false) != (rhs.selected ?? false) {
                return (lhs.selected ?? false) && !(rhs.selected ?? false)
            }
            return lhs.id < rhs.id
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingArtwork {
                    ProgressView("Loading artwork")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if artworkOptions.isEmpty {
                    ContentUnavailableView(
                        "No Artwork Found",
                        systemImage: "photo.on.rectangle",
                        description: Text("Plex did not return any available artwork options for this album.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(sortedArtworkOptions) { artwork in
                                artworkOptionButton(for: artwork)
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Change Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isApplyingArtwork)
                }
            }
        }
        .task {
            await loadArtworkOptions()
        }
        .alert(
            "Unable to Change Artwork",
            isPresented: .init(
                get: { artworkErrorMessage != nil },
                set: { if !$0 { artworkErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(artworkErrorMessage ?? "")
        }
    }

    private func artworkOptionButton(for artwork: PlexImageResource) -> some View {
        Button {
            Task {
                await applyArtwork(artwork)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ArtworkView(
                    thumbPath: artwork.thumb ?? artwork.url ?? artwork.key,
                    size: artworkTileSize,
                    cornerRadius: 12,
                    useCache: false
                )
                    .frame(maxWidth: .infinity)
                if artwork.selected ?? false {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }
                if applyingArtworkID == artwork.id {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .padding(4)
        }
        .buttonStyle(.plain)
        .disabled(isApplyingArtwork)
    }

    @MainActor
    private func loadArtworkOptions() async {
        guard let server = serverConnection.currentServer else {
            isLoadingArtwork = false
            return
        }
        isLoadingArtwork = true
        defer { isLoadingArtwork = false }

        do {
            let metadataOptions = try await client.getMetadataArtworkOptions(
                server: server,
                ratingKey: albumRatingKey
            )
            let resourceOptions = try await client.getArtworkResources(
                server: server,
                ratingKey: albumRatingKey,
                element: "posters"
            )
            if !resourceOptions.isEmpty {
                artworkOptions = displayArtworkOptions(from: resourceOptions)
            } else {
                artworkOptions = displayArtworkOptions(from: metadataOptions)
            }
        } catch {
            artworkErrorMessage = error.localizedDescription
            artworkOptions = []
        }
    }

    private func displayArtworkOptions(from options: [PlexImageResource]) -> [PlexImageResource] {
        let merged = deduplicatedArtworkOptions(options)
        let hasSelectionMarker = merged.contains(where: { $0.selected == true })
        if hasSelectionMarker, merged.count > 1 {
            let filtered = merged.filter { $0.selected != true }
            if !filtered.isEmpty {
                return filtered
            }
        }
        return merged
    }

    private func deduplicatedArtworkOptions(_ options: [PlexImageResource]) -> [PlexImageResource] {
        var seen = Set<String>()
        var merged: [PlexImageResource] = []
        for option in options {
            let identity = [option.key, option.url, option.thumb]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? option.id
            if seen.insert(identity).inserted {
                merged.append(option)
            }
        }
        return merged
    }

    @MainActor
    private func applyArtwork(_ artwork: PlexImageResource) async {
        guard let server = serverConnection.currentServer else { return }
        let artworkCandidates = orderedUniqueArtworkCandidates(for: artwork)
        guard !artworkCandidates.isEmpty else {
            artworkErrorMessage = "Artwork URL is missing for this option."
            return
        }
        guard !isApplyingArtwork else { return }

        isApplyingArtwork = true
        applyingArtworkID = artwork.id
        defer {
            isApplyingArtwork = false
            applyingArtworkID = nil
        }

        do {
            let originalThumb = try? await client.getMetadata(server: server, ratingKey: albumRatingKey)?.thumb
            var applied = false

            for candidate in artworkCandidates {
                try await client.setArtworkResource(
                    server: server,
                    ratingKey: albumRatingKey,
                    element: "poster",
                    artworkURL: candidate
                )

                let thumbChanged = await waitForThumbChange(
                    server: server,
                    originalThumb: originalThumb
                )
                if thumbChanged {
                    applied = true
                    break
                }
            }

            guard applied else {
                artworkErrorMessage = "Unable to change artwork."
                return
            }

            await LibraryCache.shared.remove(forKey: CacheKey.metadata(ratingKey: albumRatingKey))
            await ImageCache.shared.clearAll()
            await onArtworkChanged()
            dismiss()
        } catch {
            artworkErrorMessage = error.localizedDescription
        }
    }

    private func orderedUniqueArtworkCandidates(for artwork: PlexImageResource) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in [artwork.key, artwork.url, artwork.thumb] {
            for candidate in expandedArtworkCandidates(from: value) {
                if seen.insert(candidate).inserted {
                    result.append(candidate)
                }
            }
        }
        return result.sorted { lhs, rhs in
            candidatePriority(lhs) < candidatePriority(rhs)
        }
    }

    private func expandedArtworkCandidates(from value: String?) -> [String] {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return [] }

        var candidates: [String] = [raw]

        if let decoded = raw.removingPercentEncoding, !decoded.isEmpty, decoded != raw {
            candidates.append(decoded)
        }

        if let components = URLComponents(string: raw),
           let wrapped = components.queryItems?.first(where: { $0.name == "url" })?.value,
           !wrapped.isEmpty {
            candidates.append(wrapped)
            if let wrappedDecoded = wrapped.removingPercentEncoding,
               !wrappedDecoded.isEmpty,
               wrappedDecoded != wrapped {
                candidates.append(wrappedDecoded)
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func candidatePriority(_ candidate: String) -> Int {
        let lower = candidate.lowercased()
        if lower.hasPrefix("upload://") { return 0 }
        if lower.hasPrefix("metadata://") { return 1 }
        if lower.contains("url=upload://") || lower.contains("url=metadata://") { return 2 }
        if lower.contains("/library/metadata/") && lower.contains("/file?url=") { return 3 }
        return 4
    }

    private func waitForThumbChange(server: PlexServer, originalThumb: String?) async -> Bool {
        for _ in 0..<4 {
            if let latestThumb = try? await client.getMetadata(server: server, ratingKey: albumRatingKey)?.thumb,
               latestThumb != originalThumb {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

}

#Preview {
    ChangeAlbumArtworkSheet(
        albumRatingKey: "1",
        onArtworkChanged: {}
    )
}
