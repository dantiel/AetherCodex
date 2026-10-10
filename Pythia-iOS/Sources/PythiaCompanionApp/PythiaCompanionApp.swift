import SwiftUI
import Pythia

/// The Pythia Companion — the oracle on iOS. Two faces, one identity:
/// the connection veil, then the conversation. Chrome withdraws; the chat remains.
@main
struct PythiaCompanionApp: App {
    @StateObject private var model = PythiaCompanionModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if case .connected = model.connection {
                    ChatView(model: model)
                } else {
                    ConnectionView(model: model)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
