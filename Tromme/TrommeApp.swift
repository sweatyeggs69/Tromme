import SwiftUI
import UIKit

@main
struct TrommeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var serverConnection = ServerConnectionManager()
    @State private var plexClient = PlexAPIClient()
    @State private var audioPlayer = AudioPlayerService()
    @State private var configuredCatalystSceneIDs: Set<String> = []

    init() {
        // Populate shared context so CarPlay (and other non-SwiftUI code) can access services
        let ctx = AppContext.shared
        ctx.serverConnection = serverConnection
        ctx.plexClient = plexClient
        ctx.audioPlayer = audioPlayer
        if let server = serverConnection.currentServer {
            audioPlayer.configure(server: server, client: plexClient)
        }

        let accentColor = UIColor(AppStyle.Colors.tint)
        UINavigationBar.appearance().tintColor = .label

        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        tabBarAppearance.stackedLayoutAppearance.selected.iconColor = accentColor
        tabBarAppearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accentColor]
        tabBarAppearance.inlineLayoutAppearance.selected.iconColor = accentColor
        tabBarAppearance.inlineLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accentColor]
        tabBarAppearance.compactInlineLayoutAppearance.selected.iconColor = accentColor
        tabBarAppearance.compactInlineLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accentColor]

        let tabBarProxy = UITabBar.appearance()
        tabBarProxy.tintColor = accentColor
        tabBarProxy.standardAppearance = tabBarAppearance
        tabBarProxy.scrollEdgeAppearance = tabBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(AppStyle.Colors.tint)
                .environment(\.serverConnection, serverConnection)
                .environment(\.plexClient, plexClient)
                .environment(audioPlayer)
                .onChange(of: serverConnection.currentServer, initial: true) { old, server in
                    if let old, old.machineIdentifier != server?.machineIdentifier {
                        audioPlayer.resetPlayback()
                    }
                    if let server {
                        audioPlayer.configure(server: server, client: plexClient)
                    }
                }
                .onChange(of: serverConnection.currentLibrarySectionId) { old, new in
                    if let old, let new, old != new {
                        audioPlayer.resetPlayback()
                    }
                }
                .task {
                    // Warm cache on launch if already signed in
                    guard let server = serverConnection.currentServer,
                          let sectionId = serverConnection.currentLibrarySectionId else { return }
                    // Let the first frame render before heavy background warming work starts.
                    try? await Task.sleep(for: .seconds(1.5))
                    serverConnection.warmCache(server: server, sectionId: sectionId, client: plexClient)
                }
                .task {
                    await observeMemoryWarnings()
                }
                .task {
                    await observeAppTermination()
                }
                .task {
                    await MainActor.run {
                        configureCatalystWindowGeometryIfNeeded()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await ImageCache.shared.clearMemory() }
            }
            if phase == .active {
                Task {
                    guard let server = serverConnection.currentServer,
                          let sectionId = serverConnection.currentLibrarySectionId else { return }
                    // Check if library has actually changed before rebuilding cache
                    guard let sections = try? await plexClient.getLibrarySections(server: server),
                          let section = sections.first(where: { $0.key == sectionId }),
                          let serverUpdatedAt = section.updatedAt else { return }
                    let lastUpdatedAt = UserDefaults.standard.integer(forKey: "lastLibraryUpdatedAt")
                    guard serverUpdatedAt > lastUpdatedAt else { return }
                    UserDefaults.standard.set(serverUpdatedAt, forKey: "lastLibraryUpdatedAt")
                    await LibraryCache.shared.clearAll()
                    await plexClient.warmCache(server: server, sectionId: sectionId)
                }
            }
        }
    }

    private func observeMemoryWarnings() async {
        for await _ in NotificationCenter.default.notifications(
            named: UIApplication.didReceiveMemoryWarningNotification
        ) {
            await ImageCache.shared.clearMemory()
        }
    }

    private func observeAppTermination() async {
        for await _ in NotificationCenter.default.notifications(
            named: UIApplication.willTerminateNotification
        ) {
            await MainActor.run {
                audioPlayer.reportStoppedForAppTermination()
            }
        }
    }

    @MainActor
    private func configureCatalystWindowGeometryIfNeeded() {
#if targetEnvironment(macCatalyst)
        let initialSize = CGSize(width: 1024, height: 768)
        let minimumSize = CGSize(width: 768, height: 576)
        let maximumSize = CGSize(width: 1365, height: 1024)

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            let sceneID = windowScene.session.persistentIdentifier
            guard !configuredCatalystSceneIDs.contains(sceneID) else { continue }

            if let restrictions = windowScene.sizeRestrictions {
                restrictions.minimumSize = minimumSize
                restrictions.maximumSize = maximumSize
                restrictions.allowsFullScreen = false
            }

            let preferences = UIWindowScene.GeometryPreferences.Mac()
            preferences.systemFrame = CGRect(origin: .zero, size: initialSize)
            windowScene.requestGeometryUpdate(preferences) { error in
#if DEBUG
                print("Failed to update Catalyst window geometry: \(error.localizedDescription)")
#endif
            }
            configuredCatalystSceneIDs.insert(sceneID)
        }
#endif
    }
}
