import AppIntents

struct TrommeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Play \(\.$item) on \(.applicationName)",
                "Play music in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
    }
}
