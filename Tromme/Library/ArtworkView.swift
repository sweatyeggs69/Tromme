import SwiftUI

struct ArtworkView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    let thumbPath: String?
    var size: CGFloat = 60
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?
    private var safeSize: CGFloat {
        max(size, 0)
    }

    private var transcodePx: Int {
        if safeSize <= 100 { return 300 }
        if safeSize <= 300 { return 700 }
        return 1000
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
        .task(id: thumbPath) {
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
        guard let url = artworkURL(for: path) else {
            image = nil
            return
        }
        let resolvedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled, path == thumbPath else { return }
        image = resolvedImage
    }
}

#Preview {
    ArtworkView(thumbPath: nil, size: 120)
}
