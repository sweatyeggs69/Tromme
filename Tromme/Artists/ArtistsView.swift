import SwiftUI

struct ArtistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(NetworkStatus.self) private var network
    @Environment(DownloadManager.self) private var downloadManager

    @State private var artists: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var indexTitle: String?
    @AppStorage("artistsViewMode") private var viewMode: ArtistsViewMode = .list

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegularLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var gridColumnSpacing: CGFloat {
        isRegularLayout ? 16 : 8
    }

    private var gridRowSpacing: CGFloat {
        isRegularLayout ? 18 : 10
    }

    private var gridHorizontalPadding: CGFloat {
        isRegularLayout ? 24 : 16
    }

    private var columns: [GridItem] {
        let count = isRegularLayout ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: gridColumnSpacing), count: count)
    }

    private var artistSections: [(title: String, items: [PlexMetadata])] {
        alphabetSections(for: artists) { artist in
            artistSortKey(for: artist.title)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentView
            }
        }
        .navigationTitle("Artists")
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewMode = viewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(.primary)
                .accessibilityLabel(viewMode == .grid ? "Show as list" : "Show as grid")
            }
        }
        .task(id: loadTaskID) { await loadArtists() }
        .task(id: artworkPrefetchKey) { await prefetchVisibleArtwork() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .libraryContentDidChange) {
                guard !Task.isCancelled else { break }
                await loadArtists()
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .list:
            List {
                ForEach(artistSections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { artist in
                            NavigationLink(value: artist) {
                                HStack(spacing: 10) {
                                    ArtworkView(
                                        thumbPath: artist.thumb,
                                        size: AppStyle.AlbumLayout.listArtworkSize,
                                        cornerRadius: AppStyle.AlbumLayout.listArtworkSize / 2
                                    )

                                    Text(artist.title)
                                        .font(.body)
                                }
                            }
                            .listRowInsets(AppStyle.TrackList.rowInsets)
                        }
                    }
                    .sectionIndexLabel(section.title)
                }
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(.automatic)
            .tint(.secondary)

        case .grid:
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(artistSections, id: \.title) { section in
                        Text(section.title)
                            .id(section.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, gridHorizontalPadding)

                        LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                            ForEach(section.items) { artist in
                                NavigationLink(value: artist) {
                                    VStack(alignment: .center, spacing: 4) {
                                        GeometryReader { geo in
                                            let size = geo.size.width
                                            ArtworkView(thumbPath: artist.thumb, size: size, cornerRadius: size / 2)
                                        }
                                        .aspectRatio(1, contentMode: .fit)

                                        Text(artist.title)
                                            .appItemTitleStyle()
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, gridHorizontalPadding)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, AppStyle.Spacing.sectionIndexInset)
            }
            .overlay(alignment: .trailing) {
                SectionIndexBar(titles: artistSections.map(\.title), activeTitle: $indexTitle) { title in
                    proxy.scrollTo(title, anchor: .top)
                }
                .padding(.trailing, 0)
            }
            .overlay { SectionIndexPopup(title: indexTitle) }
            }
            .tint(.secondary)
        }
    }

    private var loadTaskID: String {
        let serverID = serverConnection.currentServer?.machineIdentifier ?? "none"
        let sectionID = serverConnection.currentLibrarySectionId ?? "none"
        return "\(serverID)|\(sectionID)|\(network.isConnected)"
    }

    private var artworkPrefetchKey: String {
        "\(viewMode.rawValue)|\(artists.count)"
    }

    private func loadArtists() async {
        if network.isConnected {
            await loadArtistsOnline()
        } else {
            await loadArtistsOffline()
        }
    }

    private func loadArtistsOffline() async {
        var cachedByKey: [String: PlexMetadata] = [:]
        if let server = serverConnection.currentServer,
           let sectionId = serverConnection.currentLibrarySectionId {
            let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
            let cached = await LibraryStore.shared.items(kind: LibraryStore.Kind.artist, scope: scope)
            cachedByKey = Dictionary(cached.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var seen = Set<String>()
        var result: [PlexMetadata] = []
        for record in downloadManager.downloadedTracksSorted {
            let key = record.artistRatingKey ?? record.artistName
            guard seen.insert(key).inserted else { continue }
            if let ratingKey = record.artistRatingKey, let cached = cachedByKey[ratingKey] {
                result.append(cached)
                continue
            }
            result.append(PlexMetadata(
                ratingKey: record.artistRatingKey ?? "offline:\(record.artistName)",
                title: record.artistName,
                type: "artist",
                parentTitle: nil,
                thumb: record.thumbPath
            ))
        }
        result.sort { artistSortKey(for: $0.title) < artistSortKey(for: $1.title) }
        withAnimation(.easeIn(duration: 0.25)) {
            artists = result
            isLoading = false
        }
    }

    private func loadArtistsOnline() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else {
            isLoading = false
            return
        }

        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        if let cached = LibraryStore.memory.items(scope: scope, kind: LibraryStore.Kind.artist), !cached.isEmpty {
            var sorted = cached
            sorted.sort { artistSortKey(for: $0.title) < artistSortKey(for: $1.title) }
            artists = sorted
            isLoading = false
        }

        do {
            var result = try await client.cachedArtists(server: server, sectionId: sectionId)
            result.sort { artistSortKey(for: $0.title) < artistSortKey(for: $1.title) }
            withAnimation(.easeIn(duration: 0.25)) {
                artists = result
                isLoading = false
            }
        } catch {
            #if DEBUG
            print("[ArtistsView] Failed to load artists: \(error.localizedDescription)")
            #endif
            isLoading = false
        }

        let knownKeys = Set(artists.map(\.ratingKey))
        guard let tracks = try? await client.cachedTracks(server: server, sectionId: sectionId) else { return }
        var seen = Set<String>()
        var orphans: [PlexMetadata] = []
        for track in tracks {
            guard let key = track.grandparentRatingKey,
                  !knownKeys.contains(key),
                  seen.insert(key).inserted,
                  let name = track.grandparentTitle else { continue }
            orphans.append(PlexMetadata(
                ratingKey: key,
                title: name,
                type: "artist",
                thumb: track.grandparentThumb
            ))
        }
        guard !orphans.isEmpty else { return }
        var merged = artists + orphans
        merged.sort { artistSortKey(for: $0.title) < artistSortKey(for: $1.title) }
        withAnimation(.easeIn(duration: 0.25)) {
            artists = merged
        }
    }

    private func prefetchVisibleArtwork() async {
        guard !isLoading, let server = serverConnection.currentServer else { return }
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let prefetchCount = viewMode == .grid ? 60 : 80
        let pointSize: CGFloat = viewMode == .grid ? 184 : AppStyle.AlbumLayout.listArtworkSize
        let pixelSize = ArtworkView.recommendedTranscodeSize(pointSize: pointSize, displayScale: displayScale)
        let urls = artists.prefix(prefetchCount).compactMap { artist in
            client.artworkURL(server: server, path: artist.thumb, width: pixelSize, height: pixelSize)
        }
        await ImageCache.shared.prefetch(urls: urls, targetPixelSize: pixelSize, maxConcurrent: 4)
    }

    private func artistSortKey(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let withoutThe: String
        if lower.hasPrefix("the ") {
            withoutThe = String(trimmed.dropFirst(4))
        } else if lower.hasSuffix(", the") {
            withoutThe = String(trimmed.dropLast(5))
        } else {
            withoutThe = trimmed
        }

        let normalized = withoutThe.trimmingCharacters(in: .whitespacesAndNewlines)

        let firstWord = normalized
            .split(whereSeparator: \.isWhitespace)
            .first.map(String.init) ?? normalized

        return "\(firstWord.lowercased())|\(normalized.lowercased())"
    }

    private func alphabetSections(
        for items: [PlexMetadata],
        sortKey: (PlexMetadata) -> String
    ) -> [(title: String, items: [PlexMetadata])] {
        var sectionItems: [String: [PlexMetadata]] = [:]
        var sectionOrder: [String] = []
        for item in items {
            let title = alphabetSectionTitle(for: sortKey(item))
            if sectionItems[title] == nil { sectionOrder.append(title) }
            sectionItems[title, default: []].append(item)
        }
        return sectionOrder.map { ($0, sectionItems[$0]!) }
    }

    private func alphabetSectionTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let letter = String(first).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
    }
}

#Preview {
    NavigationStack {
        ArtistsView()
    }
}
