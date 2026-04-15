import SwiftUI

struct ArtworkView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

    let thumbPath: String?
    var size: CGFloat = 60
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?
    private var safeSize: CGFloat {
        max(size, 1)
    }

    private var transcodePx: Int {
        Self.recommendedTranscodeSize(pointSize: safeSize, displayScale: displayScale)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
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
        let resolvedImage = await ImageCache.shared.image(for: url, targetPixelSize: transcodePx)
        guard !Task.isCancelled, path == thumbPath else { return }
        image = resolvedImage
    }
}

extension ArtworkView {
    static func recommendedTranscodeSize(pointSize: CGFloat, displayScale: CGFloat) -> Int {
        let safePointSize = max(pointSize, 1)
        let target = Int(ceil(safePointSize * displayScale))
        switch target {
        case ...128: return 160
        case ...220: return 256
        case ...360: return 384
        case ...520: return 512
        case ...760: return 640
        default: return 896
        }
    }
}

#Preview {
    ArtworkView(thumbPath: nil, size: 120)
}
