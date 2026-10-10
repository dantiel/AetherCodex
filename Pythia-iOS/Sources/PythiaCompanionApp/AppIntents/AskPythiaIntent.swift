import AppIntents
import SwiftUI
import Pythia

/// Ask the oracle — the calculating space — a question. The reply returns as a
/// snippet, so Siri/Spotlight/Shortcuts can surface the oracle without opening the
/// companion app. `companion` routes the turn through a pantheon voice.
///
/// This is the iOS face of the channel (`siri = pythia`); the macOS host exposes the
/// same channel as `AskAetherIntent` in `AetherCodex/App/AetherAppIntents.swift`.
struct AskPythiaIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Pythia"

    @Parameter(title: "Question")
    var prompt: String

    @Parameter(title: "Companion")
    var companion: CompanionVoice?

    // iOS 17: the pre-`supportedModes` way to keep the intent non-app-launching.
    // Deprecated in iOS 26 (see docs/app-intents-and-snippets.md §6).
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some ShowsSnippetView {
        guard let client = OracleConnectionStore.shared.makeClient() else {
            return .result {
                OracleErrorSnippet(message: "No oracle answers. Connect to your Mac's daemon once from the app.")
            }
        }

        do {
            let answer = try await client.invoke(
                prompt: prompt,
                companion: companion?.rawValue,
                history: []
            )
            return .result {
                OracleAnswerSnippet(
                    glyph: companion?.glyph ?? "🐍",
                    voice: companion?.displayName ?? "Pythia",
                    answer: answer.answer.isEmpty ? "The oracle returned no answer." : answer.answer
                )
            }
        } catch {
            return .result {
                OracleErrorSnippet(message: error.localizedDescription)
            }
        }
    }
}
