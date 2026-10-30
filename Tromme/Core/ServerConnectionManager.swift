import Foundation
import SwiftUI

// MARK: - ServerConnectionManager

@Observable @MainActor
final class ServerConnectionManager {
    var currentServer: PlexServer?
    var currentLibrarySectionId: String?

    private static let serverKey = "currentServer"
    private static let serverTokenKey = "plexServerAccessToken"
    private static let libraryKey = "currentLibrarySectionId"

    private var reprobeTask: Task<Void, Never>?
    private var networkObservation: Task<Void, Never>?
    private var warmingTask: Task<Void, Never>?

    init() {
        self.currentServer = Self.loadPersistedServer()
        self.currentLibrarySectionId = UserDefaults.standard.string(forKey: Self.libraryKey)

        networkObservation = Task { [weak self] in
            var lastType = NetworkStatus.shared.interfaceType
            var lastConnected = NetworkStatus.shared.isConnected
            for await _ in NotificationCenter.default.notifications(named: NetworkStatus.didChangeNotification) {
                guard !Task.isCancelled else { return }
                let currentType = NetworkStatus.shared.interfaceType
                let currentConnected = NetworkStatus.shared.isConnected
                if currentType != lastType || (!lastConnected && currentConnected) {
                    lastType = currentType
                    lastConnected = currentConnected
                    self?.scheduleReprobe()
                } else {
                    lastConnected = currentConnected
                }
            }
        }

        if currentServer != nil {
            scheduleReprobe()
        }
    }

    func connect(to server: PlexServer) {
        currentServer = server
        Self.persist(server)
    }

    private struct StoredServer: Codable {
        let name: String
        let uri: String
        let machineIdentifier: String
        let connections: [PlexConnection]
    }

    private static func persist(_ server: PlexServer) {
        let stored = StoredServer(
            name: server.name,
            uri: server.uri,
            machineIdentifier: server.machineIdentifier,
            connections: server.connections
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        KeychainHelper.save(server.accessToken, forKey: serverTokenKey)
        try? data.write(to: serverFileURL, options: .atomic)
        UserDefaults.standard.removeObject(forKey: serverKey)
    }

    private static var serverFileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommeState", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "currentServer.json")
    }

    private static func loadPersistedServer() -> PlexServer? {
        if let data = try? Data(contentsOf: serverFileURL) {
            return decodeStoredServer(data)
        }
        guard let data = UserDefaults.standard.data(forKey: serverKey) else { return nil }
        if let legacy = try? JSONDecoder().decode(PlexServer.self, from: data) {
            persist(legacy)
            return legacy
        }
        guard let server = decodeStoredServer(data) else { return nil }
        persist(server)
        return server
    }

    private static func decodeStoredServer(_ data: Data) -> PlexServer? {
        guard let stored = try? JSONDecoder().decode(StoredServer.self, from: data),
              let token = KeychainHelper.load(forKey: serverTokenKey) else { return nil }
        return PlexServer(
            name: stored.name,
            uri: stored.uri,
            machineIdentifier: stored.machineIdentifier,
            accessToken: token,
            connections: stored.connections
        )
    }

    func selectLibrary(_ sectionId: String, client: PlexAPIClient? = nil) {
        let changed = currentLibrarySectionId != sectionId
        currentLibrarySectionId = sectionId
        UserDefaults.standard.set(sectionId, forKey: Self.libraryKey)
        if changed {
            if let serverId = currentServer?.machineIdentifier {
                UserDefaults.standard.removeObject(forKey: "lastLibraryUpdatedAt_\(serverId)_\(sectionId)")
            }
            UserDefaults.standard.removeObject(forKey: "lastLibraryUpdatedAt") // legacy key
        }
        if let server = currentServer, let client {
            warmCache(server: server, sectionId: sectionId, client: client)
        }
    }

    func warmCache(server: PlexServer, sectionId: String, client: PlexAPIClient) {
        warmingTask?.cancel()
        warmingTask = Task {
            await client.smartRefresh(server: server, sectionId: sectionId)
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
        try? FileManager.default.removeItem(at: Self.serverFileURL)
        KeychainHelper.delete(forKey: Self.serverTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.libraryKey)
        UserDefaults.standard.removeObject(forKey: "lastLibraryUpdatedAt")
        Task {
            await ExternalContentCache.shared.clearAll()
            await LibraryStore.shared.deleteAll()
            await ImageCache.shared.clearAll()
        }
    }

    var isConnected: Bool {
        currentServer != nil && currentLibrarySectionId != nil
    }

    // MARK: - Auto-Discovery

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

    var availableServers: [PlexServer] = []

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
                await ExternalContentCache.shared.clearAll()
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

    static func probe(
        connections: [PlexConnection],
        token: String,
        timeout: TimeInterval
    ) async -> String? {
        let localURIs = connections.compactMap { c -> String? in
            guard c.local == true else { return nil }
            return c.uri
        }
        let remoteURIs = connections.compactMap { c -> String? in
            guard c.local != true, c.relay != true else { return nil }
            return c.uri
        }
        let relayURIs = connections.compactMap { c -> String? in
            guard c.relay == true else { return nil }
            return c.uri
        }

        if let bestLocal = await firstReachableURI(in: localURIs, token: token, timeout: timeout) {
            return bestLocal
        }
        if let bestRemote = await firstReachableURI(in: remoteURIs, token: token, timeout: timeout) {
            return bestRemote
        }
        return await firstReachableURI(in: relayURIs, token: token, timeout: timeout)
    }

    private static func firstReachableURI(
        in uris: [String],
        token: String,
        timeout: TimeInterval
    ) async -> String? {
        guard !uris.isEmpty else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            for uri in uris {
                group.addTask {
                    await testURI(uri, token: token, timeout: timeout) ? uri : nil
                }
            }
            for await result in group {
                if let reachable = result {
                    group.cancelAll()
                    return reachable
                }
            }
            return nil
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
