import PhotosUI
import SwiftUI

struct ChangeArtworkSheet: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss

    let ratingKey: String
    var subject = "album"
    let onArtworkChanged: @MainActor () async -> Void

    @State private var artworkOptions: [PlexImageResource] = []
    @State private var isLoadingArtwork = true
    @State private var isApplyingArtwork = false
    @State private var applyingArtworkID: String?
    @State private var artworkErrorMessage: String?
    @State private var showingPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingURLPrompt = false
    @State private var customArtworkURL = ""
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

    private func artworkTileSize(containerWidth: CGFloat) -> CGFloat {
        let columnCount = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        let totalSpacing = gridSpacing * CGFloat(max(columnCount - 1, 0))
        let available = containerWidth - (horizontalInset * 2) - totalSpacing
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
                        description: Text("Plex did not return any available artwork options for this \(subject).")
                    )
                } else {
                    GeometryReader { proxy in
                        let tileSize = artworkTileSize(containerWidth: proxy.size.width)
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: gridSpacing) {
                                ForEach(sortedArtworkOptions) { artwork in
                                    artworkOptionButton(for: artwork, tileSize: tileSize)
                                }
                            }
                            .padding(.horizontal, horizontalInset)
                            .padding(.vertical, 12)
                        }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Upload Photo", systemImage: "photo") {
                            showingPhotoPicker = true
                        }
                        Button("Add from URL", systemImage: "link") {
                            customArtworkURL = ""
                            showingURLPrompt = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isLoadingArtwork || isApplyingArtwork)
                }
            }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            Task { await uploadPhoto(item) }
        }
        .alert("Artwork URL", isPresented: $showingURLPrompt) {
            TextField("https://", text: $customArtworkURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let value = customArtworkURL.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await applyCustomURL(value) }
            }
        } message: {
            Text("Enter the web address of an image for this \(subject).")
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

    private func artworkOptionButton(for artwork: PlexImageResource, tileSize: CGFloat) -> some View {
        Button {
            Task {
                await applyArtwork(artwork)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ArtworkView(
                    thumbPath: preferredArtworkPath(for: artwork),
                    size: tileSize,
                    cornerRadius: 12,
                    useCache: false,
                    minimumTranscodePx: 1000
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
                ratingKey: ratingKey
            )
            let resourceOptions = try await client.getArtworkResources(
                server: server,
                ratingKey: ratingKey,
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
            let originalThumb = try? await client.getMetadata(server: server, ratingKey: ratingKey)?.thumb
            var applied = false

            for candidate in artworkCandidates {
                try await client.setArtworkResource(
                    server: server,
                    ratingKey: ratingKey,
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

            if let fresh = try? await client.getMetadata(server: server, ratingKey: ratingKey) {
                await LibraryStore.shared.replaceListing(fresh, serverId: server.machineIdentifier)
            }
            await onArtworkChanged()
            dismiss()
        } catch {
            artworkErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func uploadPhoto(_ item: PhotosPickerItem) async {
        guard !isApplyingArtwork else { return }
        isApplyingArtwork = true
        defer { isApplyingArtwork = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.95) else {
                artworkErrorMessage = "Unable to read the selected photo."
                return
            }
            try await applyCustomArtwork { server in
                try await client.uploadArtwork(server: server, ratingKey: ratingKey, imageData: jpeg)
            }
        } catch {
            artworkErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applyCustomURL(_ value: String) async {
        guard !isApplyingArtwork else { return }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
            try? await Task.sleep(for: .milliseconds(400))
            artworkErrorMessage = "Enter a valid http or https address."
            return
        }
        isApplyingArtwork = true
        defer { isApplyingArtwork = false }
        do {
            try await applyCustomArtwork { server in
                try await client.setArtworkResource(
                    server: server,
                    ratingKey: ratingKey,
                    element: "poster",
                    artworkURL: value
                )
            }
        } catch {
            artworkErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applyCustomArtwork(_ send: (PlexServer) async throws -> Void) async throws {
        guard let server = serverConnection.currentServer else { return }
        let originalThumb = try? await client.getMetadata(server: server, ratingKey: ratingKey)?.thumb
        try await send(server)
        guard await waitForThumbChange(server: server, originalThumb: originalThumb) else {
            artworkErrorMessage = "Unable to change artwork."
            return
        }
        if let fresh = try? await client.getMetadata(server: server, ratingKey: ratingKey) {
            await LibraryStore.shared.replaceListing(fresh, serverId: server.machineIdentifier)
        }
        await onArtworkChanged()
        dismiss()
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

    private func preferredArtworkPath(for artwork: PlexImageResource) -> String? {
        let values = [artwork.url, artwork.key, artwork.thumb]
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
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
        for _ in 0..<20 {
            if let latestThumb = try? await client.getMetadata(server: server, ratingKey: ratingKey)?.thumb,
               latestThumb != originalThumb {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

}

#Preview {
    ChangeArtworkSheet(
        ratingKey: "1",
        onArtworkChanged: {}
    )
}
