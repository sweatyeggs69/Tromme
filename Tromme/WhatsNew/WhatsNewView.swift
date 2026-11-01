import SwiftUI

struct WhatsNewView: View {
    let release: WhatsNewRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text(release.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(release.features) { feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.symbol)
                                .font(.title)
                                .foregroundStyle(.tint)
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
            }

            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.large])
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        WhatsNewView(release: WhatsNewContent.current)
    }
}
