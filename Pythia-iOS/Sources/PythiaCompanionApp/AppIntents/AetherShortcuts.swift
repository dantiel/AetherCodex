import AppIntents

/// Registers the oracle intents with Siri / Spotlight / Shortcuts.
struct AetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPythiaIntent(),
            phrases: [
                "Ask Pythia ${applicationName} \\(\\.$prompt)",
                "Ask the oracle ${applicationName} \\(\\.$prompt)",
                "${applicationName} \\(\\.$prompt)"
            ],
            shortTitle: "Ask Pythia",
            systemImageName: "sparkles"
        )
    }
}