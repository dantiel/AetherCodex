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

    /// The oracle's audible voice — a premium-tuned speech engine that speaks
    /// answers in the active companion's persona when `autoSpeak` is on.
    let voice = PythiaVoice()

    /// Bonjour discovery — finds the Mac on the LAN without an IP address.
    private let bonjour = AetherBonjour()

    var activeCompanion: Companion {
        pythiaCompanions.first { $0.id == companionID } ?? pythiaCompanions[0]
    }

    /// Manual scan: probe the daemon port range on one explicit host.
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

    /// Auto-discovery: browse `_aethercodex._tcp` via Bonjour and connect to the
    /// first Mac that answers — no IP required. Polls the resolver for a short
    /// window, then falls back to disconnected with a hint.
    func autoDiscover() async {
        guard !bonjour.isSearching else { return }
        connection = .discovering
        errorText = nil
        peers = []
        bonjour.search()

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let first = bonjour.peers.first {
                peers = bonjour.peers
                connection = .connected(first)
                OracleConnectionStore.shared.save(host: first.host, port: first.port)
                bonjour.stop()
                return
            }
        }

        bonjour.stop()
        if case .discovering = connection {
            connection = .disconnected
            errorText = "No Mac found. Is AetherCodex running on this Wi-Fi?"
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

    /// The most recent user prompt — the only prompt that may be *changed*
    /// (edit loads it into the input bar; older prompts may only be forked).
    var lastUserPromptID: UUID? {
        messages.last(where: { $0.role == "user" })?.id
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, let client else { return }
        draft = ""
        errorText = nil
        let user = ChatMessage(role: "user", text: text, glyph: "✦", companionID: companionID)
        messages.append(user)
        await runTurn(prompt: text, user: user, client: client)
    }

    /// Edit the last prompt: load its text into the input bar and withdraw the
    /// last exchange (the prompt and its answer) so re-sending replaces it.
    func editLastPrompt() {
        guard !busy, let last = messages.last(where: { $0.role == "user" }) else { return }
        draft = last.text
        deletePrompt(last)
    }

    /// Fork at a prompt: keep it, drop everything after (its answer and any
    /// later turns), then re-issue the prompt to regenerate the answer.
    func regenerate(_ message: ChatMessage) async {
        guard !busy, message.role == "user", let client else { return }
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages.removeSubrange((idx + 1)...)
        }
        await runTurn(prompt: message.text, user: message, client: client)
    }

    /// Delete a prompt and everything after it — truncate the thread back to
    /// just before this prompt.
    func deletePrompt(_ message: ChatMessage) {
        guard !busy, message.role == "user",
              let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages.removeSubrange(idx...)
    }

    /// Run one oracle turn. `user` is already (or still) in `messages`; history
    /// is derived from the stream strictly *before* it, then the prompt is
    /// appended — so edit/reload/delete stay in lockstep with the wire memory.
    private func runTurn(prompt: String, user: ChatMessage, client: OracleClient) async {
        busy = true
        defer { busy = false }
        do {
            let history = historyForCurrentCompanion(before: user.id)
            let fullHistory = history + [["role": "user", "content": prompt]]
            let answer = try await client.invoke(
                prompt: prompt,
                companion: companionID,
                history: fullHistory
            )
            messages.append(ChatMessage(
                role: "assistant",
                text: answer.answer,
                glyph: activeCompanion.glyph,
                speakerName: companionID == "pythia" ? nil : activeCompanion.displayName,
                companionID: companionID
            ))
            if voice.autoSpeak {
                voice.speak(answer.answer, persona: activeCompanion.voicePersona)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// The active companion's memory, in stream order, stopping just before the
    /// given message — the turns that precede the prompt being (re-)issued.
    private func historyForCurrentCompanion(before id: UUID) -> [[String: String]] {
        var history: [[String: String]] = []
        for message in messages {
            if message.id == id { break }
            guard (message.companionID ?? "pythia") == companionID else { continue }
            history.append(["role": message.role, "content": message.text])
        }
        return history
    }
}