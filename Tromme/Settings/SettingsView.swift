import SwiftUI

struct SettingsView: View {
    var onSignOut: () -> Void

    var body: some View {
        Form {
            NavigationLink {
                ServerSettingsView(onSignOut: onSignOut)
            } label: {
                Text("Server")
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack {
        SettingsView { }
    }
}
