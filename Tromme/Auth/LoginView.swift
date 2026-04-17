import SwiftUI

struct LoginView: View {
    @Environment(\.plexClient) private var client
    @State private var authService = PlexAuthService()

    var onAuthenticated: (String) -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "music.quarternote.3")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("Tromme")
                .font(.largeTitle.bold())

            Spacer()

            if let error = authService.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task {
                    await authService.startAuth(client: client)
                }
            } label: {
                HStack {
                    if authService.isAuthenticating {
                        ProgressView()
                    }
                    Text(authService.isAuthenticating ? "Waiting for Plex..." : "Sign in with Plex")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 250)
            .disabled(authService.isAuthenticating)
            .padding(.horizontal, 32)

            Spacer()
                .frame(height: 40)
        }
        .tint(AppStyle.Colors.tint)
        .sheet(isPresented: Binding(
            get: { authService.showAuthSheet },
            set: { if !$0 { authService.cancelAuth() } }
        )) {
            if let url = authService.authURL {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: authService.authToken) { _, newToken in
            if let token = newToken {
                onAuthenticated(token)
            }
        }
    }
}

#Preview {
    LoginView { _ in }
}
