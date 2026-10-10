import Foundation
import SwiftUI
import Pythia

/// The companion's single source of truth: connection state, conversation flow,
/// the active companion voice, and the drafted prompt. Survives view rebuilds by
/// living here (and in the root view's @StateObject) rather than in leaf @State.
@MainActor
final class PythiaCompanionModel: ObservableObject {
    enum Connection: Equatable {
        case disconnected
        case discovering
        case connected(PeerContext)
    }

    @Published var connection: Connection = .disconnected
    @Published var host: String = ""
    @Published var peers: [PeerContext] = []
    @Published var messages: [ChatMessage] = []
    @Published var companionID: String = "pythia"
    @Published var busy = false
    @Published var errorText: String?
    @Published var draft: String = ""

    /// Per-voice multi-turn memory — mirrors the Mac's `companionHistories`.
    private var histories: [String: [[String: String]]] = [:]

    var activeCompanion: Companion {
        pythiaCompanions.first { $0.id == companionID } ?? pythiaCompanions[0]
    }

    func discover() async {
        connection = .discovering
        errorText = nil
        peers = await AetherLinkClient.discover(host: host)
        if let first = peers.first {
            connection = .connected(first)
            OracleConnectionStore.shared.save(host: first.host, port: first.port)
        } else {
            connection = .disconnected
            errorText = "No context answers on \(host). Is the Mac's daemon running?"
        }
    }

    func connect(to peer: PeerContext) {
        connection = .connected(peer)
        OracleConnectionStore.shared.save(host: peer.host, port: peer.port)
    }

    func disconnect() {
        connection = .disconnected
        peers = []
    }

    var client: OracleClient? {
        guard case let .connected(peer) = connection else { return nil }
        return OracleClient(host: peer.host, port: peer.port)
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, let client else { return }
        draft = ""
        errorText = nil

        messages.append(ChatMessage(role: "user", text: text, glyph: "✦"))
        busy = true
        defer { busy = false }

        do {
            var history = histories[companionID] ?? []
            history.append(["role": "user", "content": text])
            let answer = try await client.invoke(
                prompt: text,
                companion: companionID,
                history: history
            )
            histories[companionID] = history + [["role": "assistant", "content": answer.answer]]
            messages.append(ChatMessage(
                role: "assistant",
                text: answer.answer,
                glyph: activeCompanion.glyph,
                speakerName: companionID == "pythia" ? nil : activeCompanion.displayName
            ))
        } catch {
            errorText = error.localizedDescription
        }
    }
}