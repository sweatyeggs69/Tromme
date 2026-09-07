import SwiftUI
import UIKit

@main
struct TrommeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("selectedAppIconId") private var selectedAppIconId: String = "default"

    @State private var serverConnection = AppContext.shared.serverConnection
    @State private var plexClient = AppContext.shared.plexClient
    @State private var audioPlayer = AppContext.shared.audioPlayer
    @State private var downloadManager = AppContext.shared.downloadManager
    @State private var configuredCatalystSceneIDs: Set<String> = []
    @State private var lastForegroundLibraryCheck: Date = .distantPast
    /// Skip the foreground library check if it ran in the last 5 minutes —
    /// otherwise rapid app-switcher transitions cost a network round-trip each.
    private let foregroundLibraryCheckInterval: TimeInterval = 5 * 60

    private var currentTint: Color {
        AppIconOption.accentColor(for: selectedAppIconId)
    }

    init() {
        let storedId = UserDefaults.standard.string(forKey: "selectedAppIconId") ?? "default"
        let accentColor = UIColor(AppIconOption.accentColor(for: storedId))
        Self.applyTabBarAppearance(accentColor: accentColor)
    }

    private static func applyTabBarAppearance(accentColor: UIColor) {
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
                .tint(currentTint)
                .environment(\.appAccentColor, currentTint)
                .onChange(of: selectedAppIconId) { _, newId in
                    Self.applyTabBarAppearance(accentColor: UIColor(AppIconOption.accentColor(for: newId)))
                }
                .environment(\.serverConnection, serverConnection)
                .environment(\.plexClient, plexClient)
                .environment(audioPlayer)
                .environment(downloadManager)
                .environment(NetworkStatus.shared)
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
                .task(priority: .background) {
                    // On launch, check if the library changed before refreshing.
                    // smartRefresh only invalidates list keys when updatedAt advances —
                    // images and unchanged data are served from disk without any network traffic.
                    guard let server = serverConnection.currentServer,
                          let sectionId = serverConnection.currentLibrarySectionId else { return }
                    await plexClient.smartRefresh(server: server, sectionId: sectionId)
                }
                .task {
                    await observeMemoryWarnings()
                }
                .task {
                    await observeAppTermination()
                }
                .task {
                    configureCatalystWindowGeometryIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let now = Date()
                guard now.timeIntervalSince(lastForegroundLibraryCheck) >= foregroundLibraryCheckInterval else { return }
                lastForegroundLibraryCheck = now
                Task {
                    guard let server = serverConnection.currentServer,
                          let sectionId = serverConnection.currentLibrarySectionId else { return }
                    await plexClient.smartRefresh(server: server, sectionId: sectionId)
                }
            }
        }
#if targetEnvironment(macCatalyst)
        .commands {
            CommandMenu("Playback") {
                Button(audioPlayer.isPlaying ? "Pause" : "Play") {
                    audioPlayer.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
            }
        }
#endif
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
