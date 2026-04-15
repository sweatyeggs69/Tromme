import Foundation
import SwiftUI

// MARK: - ServerConnectionManager

@Observable @MainActor
final class ServerConnectionManager {
    var currentServer: PlexServer?
    var currentLibrarySectionId: String?

    private static let serverKey = "currentServer"
    private static let libraryKey = "currentLibrarySectionId"

    private var reprobeTask: Task<Void, Never>?
    private var networkObservation: Task<Void, Never>?
    private var warmingTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.serverKey),
           let server = try? JSONDecoder().decode(PlexServer.self, from: data) {
            self.currentServer = server
        }
        self.currentLibrarySectionId = UserDefaults.standard.string(forKey: Self.libraryKey)

        // Observe network changes via shared monitor
        networkObservation = Task { [weak self] in
            var lastType = NetworkStatus.shared.interfaceType
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let currentType = NetworkStatus.shared.interfaceType
                if currentType != lastType {
                    lastType = currentType
                    self?.scheduleReprobe()
                }
            }
        }

        if currentServer != nil {
            scheduleReprobe()
        }
    }

    func connect(to server: PlexServer) {
        currentServer = server
        if let data = try? JSONEncoder().encode(server) {
            UserDefaults.standard.set(data, forKey: Self.serverKey)
        }
    }

    func selectLibrary(_ sectionId: String, client: PlexAPIClient? = nil) {
        let changed = currentLibrarySectionId != sectionId
        currentLibrarySectionId = sectionId
        UserDefaults.standard.set(sectionId, forKey: Self.libraryKey)
        if changed {
            UserDefaults.standard.removeObject(forKey: "lastLibraryUpdatedAt")
            Task { await LibraryCache.shared.clearAll() }
        }
        // Warm cache for the selected library
        if let server = currentServer, let client {
            warmCache(server: server, sectionId: sectionId, client: client)
        }
    }

    /// Preload core library data in the background so views load instantly.
    func warmCache(server: PlexServer, sectionId: String, client: PlexAPIClient) {
        warmingTask?.cancel()
        warmingTask = Task {
            await client.warmCache(server: server, sectionId: sectionId)
        }
    }

    func disconnect() {
        currentServer = nil
        currentLibrarySectionId = nil
        availableServers = []
        reprobeTask?.cancel()
        reprobeTask = nil
        warmingTask?.cancel()
        warmingTask = nil
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        UserDefaults.standard.removeObject(forKey: Self.libraryKey)
        UserDefaults.standard.removeObject(forKey: "lastLibraryUpdatedAt")
        Task {
            await LibraryCache.shared.clearAll()
            await ImageCache.shared.clearAll()
        }
    }

    var isConnected: Bool {
        currentServer != nil && currentLibrarySectionId != nil
    }

    // MARK: - Auto-Discovery

    /// Discover all reachable Plex servers with music libraries.
    /// If exactly one is found, connects automatically. If multiple are found,
    /// returns them so the caller can present a picker.
    func autoDiscover(authToken: String, client: PlexAPIClient) async throws {
        let servers = try await discoverServers(authToken: authToken, client: client)
        if servers.count == 1, let only = servers.first {
            connect(to: only)
        } else if servers.isEmpty {
            throw DiscoveryError.noMusicServer
        } else {
            availableServers = servers
        }
    }

    /// All discovered servers when multiple are available.
    var availableServers: [PlexServer] = []

    /// Probes all Plex resources and returns servers with music libraries.
    func discoverServers(authToken: String, client: PlexAPIClient) async throws -> [PlexServer] {
        let resources = try await client.getResources(token: authToken)
        let candidates = resources.filter {
            $0.isServer && $0.accessToken != nil && $0.clientIdentifier != nil
        }

        var servers: [PlexServer] = []
        for resource in candidates {
            guard let token = resource.accessToken,
                  let machineId = resource.clientIdentifier else { continue }
            let connections = resource.connections ?? []

            guard let uri = await Self.probe(
                connections: connections,
                token: token,
                timeout: NetworkStatus.shared.isExpensive ? 10 : 2
            ) else { continue }

            let server = PlexServer(
                name: resource.displayName,
                uri: uri,
                machineIdentifier: machineId,
                accessToken: token,
                connections: connections
            )

            if let sections = try? await client.getLibrarySections(server: server),
               sections.contains(where: \.isMusicLibrary) {
                servers.append(server)
            }
        }
        return servers
    }

    func selectServer(_ server: PlexServer) {
        let serverChanged = currentServer?.machineIdentifier != server.machineIdentifier
        availableServers = []
        if serverChanged {
            currentLibrarySectionId = nil
            UserDefaults.standard.removeObject(forKey: Self.libraryKey)
            UserDefaults.standard.removeObject(forKey: "lastLibraryUpdatedAt")
            Task {
                await LibraryCache.shared.clearAll()
                await ImageCache.shared.clearAll()
            }
        }
        connect(to: server)
    }

    enum DiscoveryError: LocalizedError {
        case noMusicServer
        var errorDescription: String? { "No reachable Plex server with a music library was found." }
    }

    // MARK: - Connection Re-Probing

    private func scheduleReprobe() {
        reprobeTask?.cancel()
        reprobeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reprobe()
        }
    }

    func reprobe() async {
        guard let server = currentServer, !server.connections.isEmpty else { return }

        let timeout: TimeInterval = NetworkStatus.shared.isExpensive ? 10 : 2

        guard let bestURI = await Self.probe(
            connections: server.connections,
            token: server.accessToken,
            timeout: timeout
        ), bestURI != server.uri else { return }

        connect(to: PlexServer(
            name: server.name,
            uri: bestURI,
            machineIdentifier: server.machineIdentifier,
            accessToken: server.accessToken,
            connections: server.connections
        ))
    }

    // MARK: - Probing

    /// Probes ALL connections concurrently. Assigns priority: local=0, remote=1, relay=2.
    /// Returns the highest-priority reachable URI. If a local connection responds, we
    /// short-circuit immediately since nothing can outrank it.
    static func probe(
        connections: [PlexConnection],
        token: String,
        timeout: TimeInterval
    ) async -> String? {
        // Priority: local (0) > remote (1) > relay (2)
        let indexed: [(priority: Int, uri: String)] = connections.compactMap { c in
            guard let uri = c.uri else { return nil }
            if c.local == true { return (0, uri) }
            if c.relay == true { return (2, uri) }
            return (1, uri)
        }
        guard !indexed.isEmpty else { return nil }

        return await withTaskGroup(of: (Int, String)?.self) { group in
            for (priority, uri) in indexed {
                group.addTask {
                    guard await testURI(uri, token: token, timeout: timeout) else { return nil }
                    return (priority, uri)
                }
            }
            var best: (Int, String)?
            for await result in group {
                guard let r = result else { continue }
                if best == nil || r.0 < best!.0 {
                    best = r
                }
                // Local is highest priority — can't improve, stop waiting.
                if r.0 == 0 {
                    group.cancelAll()
                    return r.1
                }
            }
            return best?.1
        }
    }

    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func testURI(_ uri: String, token: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: uri) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(PlexAPIClient.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return (try? await probeSession.data(for: request))
            .flatMap { $0.1 as? HTTPURLResponse }
            .map { (200...299).contains($0.statusCode) } ?? false
    }
}

// MARK: - Environment Keys

struct ServerConnectionManagerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = ServerConnectionManager()
}

struct PlexAPIClientKey: EnvironmentKey {
    static let defaultValue = PlexAPIClient()
}

extension EnvironmentValues {
    var serverConnection: ServerConnectionManager {
        get { self[ServerConnectionManagerKey.self] }
        set { self[ServerConnectionManagerKey.self] = newValue }
    }

    var plexClient: PlexAPIClient {
        get { self[PlexAPIClientKey.self] }
        set { self[PlexAPIClientKey.self] = newValue }
    }
}
