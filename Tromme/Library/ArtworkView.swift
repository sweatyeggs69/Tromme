import SwiftUI

struct ArtworkView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

    let thumbPath: String?
    var size: CGFloat = 60
    var cornerRadius: CGFloat = 8
    var useCache: Bool = true
    var minimumTranscodePx: Int = 0

    @State private var image: UIImage?
    private var safeSize: CGFloat {
        max(size, 1)
    }

    private var transcodePx: Int {
        max(
            Self.recommendedTranscodeSize(pointSize: safeSize, displayScale: displayScale),
            minimumTranscodePx
        )
    }

    var body: some View {
        let url = artworkURL(for: thumbPath)
        let displayImage = image ?? url.flatMap {
            ImageCache.shared.memoryCachedImage(for: $0, targetPixelSize: transcodePx)
        }
        Group {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: safeSize, height: safeSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(thumbPath ?? "")_\(transcodePx)") {
            await loadImage(for: thumbPath)
        }
    }

    private func artworkURL(for path: String?) -> URL? {
        guard let server = serverConnection.currentServer else { return nil }
        return client.artworkURL(server: server, path: path, width: transcodePx, height: transcodePx)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.quaternary)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .font(.system(size: safeSize * 0.3))
        }
        .frame(width: safeSize, height: safeSize)
    }

    private func loadImage(for path: String?) async {
        guard size > 1, let url = artworkURL(for: path) else {
            image = nil
            return
        }
        let resolvedImage: UIImage?
        if useCache {
            resolvedImage = await ImageCache.shared.image(for: url, targetPixelSize: transcodePx)
        } else {
            resolvedImage = await uncachedImage(for: url)
        }
        guard !Task.isCancelled, path == thumbPath else { return }
        image = resolvedImage
    }

    private func uncachedImage(for url: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.setValue("0", forHTTPHeaderField: "Expires")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

extension ArtworkView {
    /// Largest transcode bucket, used for Now Playing and album/playlist headers.
    /// A deliberate balance: slightly below native on the largest screens
    /// (3x iPhones need ~1176px) in exchange for smaller downloads and cache files.
    static let maxTranscodePx = 1000

    static func recommendedTranscodeSize(pointSize: CGFloat, displayScale: CGFloat) -> Int {
        let safePointSize = max(pointSize, 1)
        let target = Int(ceil(safePointSize * displayScale))
        switch target {
        case ...256: return 256
        case ...512: return 512
        case ...640: return 640
        default: return maxTranscodePx
        }
    }
}

#Preview {
    ArtworkView(thumbPath: nil, size: 120)
}
