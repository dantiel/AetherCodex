import AppIntents
import SwiftUI
import Pythia

/// Read the aether's current reasoning state as a snippet — a zero-parameter
/// glance at `GET /aether/aegis`. Demonstrates that the channel carries more than
/// chat: any oracle surface can be queried.
struct AskAegisIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Æther State"

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some ShowsSnippetView {
        guard let client = OracleConnectionStore.shared.makeClient() else {
            return .result {
                OracleErrorSnippet(message: "No oracle answers. Connect to your Mac's daemon once from the app.")
            }
        }

        do {
            let state = try await client.aegis()
            return .result {
                AegisStateSnippet(
                    thinking: state.thinking,
                    temperature: state.temperature,
                    summary: state.summary
                )
            }
        } catch {
            return .result {
                OracleErrorSnippet(message: error.localizedDescription)
            }
        }
    }
}
