import SwiftUI
import StoreKit

struct AppIconPreviewImage: View {
    let named: String

    var body: some View {
        let image: UIImage? = {
            if let path = Bundle.main.path(forResource: named, ofType: "webp") {
                return UIImage(contentsOfFile: path)
            }
            return UIImage(named: named)
        }()
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: AppStyle.Radius.appIcon, style: .continuous)
                .fill(.quaternary)
                .overlay(Image(systemName: "app").font(.title2).foregroundStyle(.tertiary))
        }
    }
}
