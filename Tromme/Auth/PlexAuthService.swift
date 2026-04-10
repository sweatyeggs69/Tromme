import Foundation

@Observable @MainActor
final class PlexAuthService {
    var isAuthenticating = false
    var authToken: String?
    var error: String?
    var authURL: URL?

    private static let tokenKey = "plexAuthToken"
    private var pollTask: Task<Void, Never>?

    init() {
        authToken = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    var isAuthenticated: Bool { authToken != nil }

    /// Whether the auth sheet should be presented.
    var showAuthSheet: Bool { authURL != nil }

    func startAuth(client: PlexAPIClient) async {
        isAuthenticating = true
        error = nil

        do {
            let pin = try await client.createPin()
            let url = URL(string: "https://app.plex.tv/auth#?clientID=\(PlexAPIClient.clientIdentifier)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=\(PlexAPIClient.product)")!

            // Present the auth sheet
            authURL = url

            // Start polling for the token
            pollTask = Task {
                do {
                    let token = try await pollForToken(client: client, pinId: pin.id)
                    self.authToken = token
                    UserDefaults.standard.set(token, forKey: Self.tokenKey)
                } catch is CancellationError {
                    // User dismissed — no error
                } catch {
                    self.error = error.localizedDescription
                }

                // Dismiss the sheet and reset state
                self.authURL = nil
                self.isAuthenticating = false
            }
        } catch {
            self.error = error.localizedDescription
            isAuthenticating = false
        }
    }

    /// Called when the user manually dismisses the auth sheet.
    func cancelAuth() {
        pollTask?.cancel()
        pollTask = nil
        authURL = nil
        isAuthenticating = false
    }

    func signOut() {
        authToken = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    }

    // MARK: - Token Polling

    private func pollForToken(client: PlexAPIClient, pinId: Int) async throws -> String {
        for _ in 0..<120 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            let response = try await client.checkPin(id: pinId)
            if let token = response.authToken, !token.isEmpty {
                return token
            }
        }
        throw PlexAPIError.unauthorized
    }
}
