import AppIntents

/// Registers the oracle intents with Siri / Spotlight / Shortcuts.
struct AetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPythiaIntent(),
            phrases: [
                "Ask Pythia \(\.$prompt)",
                "Ask the oracle \(\.$prompt)",
                "\(\.$prompt)"
            ],
            shortTitle: "Ask Pythia",
            systemImageName: "sparkles"
        )
    }
}
