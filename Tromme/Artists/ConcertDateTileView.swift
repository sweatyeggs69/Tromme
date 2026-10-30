import SwiftUI

struct ConcertDateTileView: View {
    let concert: ConcertEvent
    var size: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            Text(concert.monthText)
                .font(.system(size: size * 0.25, weight: .medium))
                .foregroundStyle(.red)
            Text(concert.dayText)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

#Preview {
    ConcertDateTileView(
        concert: ConcertEvent(id: "p", city: "Mesa", region: "AZ", venue: "", address: nil, date: Date(), instant: nil, hasTime: false, url: nil)
    )
}
