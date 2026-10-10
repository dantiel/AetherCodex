import AppIntents
import SwiftUI
import Foundation

/// The macOS face of the oracle channel (`aether = oracle = the calculating space`).
/// Invoked from Shortcuts on the Mac; resolves the local `limen.rb` daemon and returns
/// the reply as a snippet. Mirrors `Pythia-iOS/.../AskPythiaIntent.swift` in shape —
/// both funnel to `POST /aether/invoke`.
struct AskAetherIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask the Æther"

    @Parameter(title: "Question")
    var prompt: String

    static var supportedModes: IntentModes = .foreground(.dynamic)

    func perform() async throws -> some ShowsSnippetView {
        do {
            let answer = try await AetherLocalOracle.invoke(prompt: prompt, companion: nil)
            return .result {
                AetherAnswerSnippet(answer: answer.isEmpty ? "The oracle returned no answer." : answer)
            }
        } catch {
            return .result {
                AetherErrorSnippet(message: error.localizedDescription)
            }
        }
    }
}

/// Registers the macOS oracle intents with Shortcuts.
struct AetherCodexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAetherIntent(),
            phrases: [
                "Ask the Æther \(\.$prompt)",
                "Ask the oracle \(\.$prompt)"
            ],
            shortTitle: "Ask the Æther",
            systemImageName: "sparkles"
        )
    }
}

// MARK: - Snippet views

struct AetherAnswerSnippet: View {
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("🐍")
                Text("Pythia").font(.headline)
            }
            Text(answer)
                .font(.body)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AetherErrorSnippet: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Oracle unreachable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Local oracle transport

/// Resolves the local daemon and submits a turn. Same HTTP contract as the iOS
/// `OracleClient`, minus cross-host discovery (the daemon is on this Mac).
enum AetherLocalOracle {
    static let defaultPort = 4567
    static let scanRange = 4550...4610

    static func invoke(prompt: String, companion: String?) async throws -> String {
        let port = await discoverPort() ?? defaultPort
        var payload: [String: Any] = [
            "prompt": prompt,
            "type": "chat",
            "from_context": "aethercodex-intents"
        ]
        if let companion, companion != "pythia" {
            payload["active_companions"] = [companion]
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/aether/invoke") else {
            throw AetherOracleError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AetherOracleError.noAnswer
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["answer"] as? String ?? ""
    }

    /// Try the default port first (fast path), then scan the discovery range.
    private static func discoverPort() async -> Int? {
        if await heartbeat(at: defaultPort) { return defaultPort }
        for port in scanRange where port != defaultPort {
            if await heartbeat(at: port) { return port }
        }
        return nil
    }

    private static func heartbeat(at port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/aether/heartbeat") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return json["name"] != nil
        } catch {
            return false
        }
    }
}

enum AetherOracleError: LocalizedError {
    case badURL
    case noAnswer

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid daemon address."
        case .noAnswer: return "The oracle did not answer. Is the Mac's daemon running?"
        }
    }
}
