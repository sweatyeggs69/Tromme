import SwiftUI

struct SettingsToolbarModifier: ViewModifier {
    @Environment(NetworkStatus.self) private var network
    let alwaysVisible: Bool

    func body(content: Content) -> some View {
        content.toolbar {
            if alwaysVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .tint(.primary)
                }
            } else if !network.isConnected {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .tint(.primary)
                }
            }
        }
    }
}
