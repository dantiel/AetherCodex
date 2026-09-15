import SwiftUI

// MARK: - Models

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let role: String  // "user" | "assistant"
    let text: String
    let glyph: String
    /// The model's reasoning_content (DeepSeek thinking mode) — rendered as a
    /// collapsible "Gedanke" block above the answer, not hidden from view.
    var reasoning: String? = nil
}

struct Companion: Identifiable {
    let id: String
    let glyph: String
    let label: String
}

/// A transient companion voice offered as a one-click macro — not part of the
/// persisted flow (no Codable churn). Clicking re-sends the prompt as a turn.
struct CompanionBubble: Identifiable, Equatable {
    let id = UUID()
    let glyph: String
    let name: String
    let prompt: String
}

/// Mirrors the companion roster of Pythia/chamber.html exactly.
/// Local fallback until the daemon's first `ready` frame arrives — the same
/// pantheon the wire roster carries, plus Pythia. Divergence here would show a
/// partial pantheon for the instant before the bridge connects (correspondence,
/// not duplication).
let pythiaCompanions: [Companion] = [
    Companion(id: "pythia", glyph: "🐍", label: "Pythia"),
    Companion(id: "owl", glyph: "🦉", label: "Owl"),
    Companion(id: "kitsune", glyph: "🦊", label: "Kitsune"),
    Companion(id: "phoenix", glyph: "🔥", label: "Phoenix"),
    Companion(id: "ouroboros", glyph: "🐍", label: "Ouroboros"),
    Companion(id: "bastet", glyph: "🐈", label: "Bastet"),
    Companion(id: "fenrir", glyph: "🐺", label: "Fenrir"),
    Companion(id: "undine", glyph: "🌊", label: "Undine"),
    Companion(id: "schwan", glyph: "🦢", label: "Schwan"),
    Companion(id: "drache", glyph: "🐉", label: "Drache"),
    Companion(id: "corax", glyph: "🐦‍⬛", label: "Corax"),
    Companion(id: "jindujun", glyph: "☁️", label: "Jindujun"),
]

struct ToolChip: Identifiable, Equatable, Codable {
    /// A chip is either a semantic instrument or a CLI block (the agent's
    /// `run_command`). CLI chips render as the unified shell block *inside* the
    /// group instead of ripping the group apart — two hands, one interface.
    enum Kind: String, Codable { case instrument, cli }

    var id = UUID()
    var kind: Kind = .instrument
    let name: String
    var args: String = ""
    var output: String = ""
    var done: Bool
    // CLI payload (populated when kind == .cli)
    var command: String = ""
    var cwd: String = ""
    var exitStatus: Int? = nil
    // Hermetic tool id — the model's tool_call id threaded through Artificer.
    // Every horologium status update for one instrumenta call shares it, so
    // file_reading → file_read_complete → tool_completed merge into one chip.
    var toolId: String? = nil
    // Live status line for the minified view; cleared on completion; never
    // affects the group's expanded state.
    // Horologium reconciliation: the many granular status frames for one tool
    // call share a single uuid — they merge into this chip instead of each
    // spawning a new entry. `status` is the live in-flight line (minified +
    // header); `detail` is the richer expanded-view note (path, bytes, …).
    var horologiumID: String? = nil
    var status: String? = nil
    var detail: String? = nil
    /// The original horologium message, HTML stripped to plain text — carries
    /// the richest in-flight/completed line (path, byte count, line range).
    /// This is what the minimized form shows, mirroring TextMate Pythia.
    var message: String? = nil
}

extension ToolChip {
    /// Richest single-line description for the minimized form — the original
    /// horologium message wins, then the live status, then detail, then the
    /// shell command (CLI) or a bare name. One line, much meaning.
    var minifiedSummary: String {
        if let message, !message.isEmpty { return message }
        if kind == .cli, !command.isEmpty { return command }
        let sem = InstrumentaSemantics.forTool(name)
        if let status, !status.isEmpty { return "\(sem.glyph) \(sem.label) \(status)" }
        if let detail, !detail.isEmpty { return "\(sem.glyph) \(sem.label) \(detail)" }
        if !args.isEmpty { return "\(sem.glyph) \(sem.label) \(name)" }
        return "\(sem.glyph) \(sem.label) \(name)"
    }
}

/// A shell command woven into the flow — the unified CLI block rendered both for
/// the user's `$` prompt and for the agent's `run_command` tool calls.
struct CliEntry: Identifiable, Equatable, Codable {
    var id = UUID()
    let command: String
    var output: String
    var cwd: String
    var exitStatus: Int?
    var done: Bool
}

/// A run of *consecutive* instrumenta calls, woven into the flow at its
/// chronological position. As long as tool calls arrive back-to-back they
/// merge into one collapsible cluster; any interleaved text or CLI block
/// closes the group and the next tool call opens a fresh one.
struct ToolGroup: Identifiable, Equatable, Codable {
    var id = UUID()
    var tools: [ToolChip] = []
    var closed = false
    var expanded = false

    /// True once every chip in the cluster has finished — swaps the in-flight
    /// spinner for a quiet checkmark in the minified summary.
    var allDone: Bool { !tools.isEmpty && tools.allSatisfy(\.done) }
}

/// One node in the unified flow timeline. Messages, tool groups and CLI
/// blocks share a single ordered list so each lands exactly where it happened
/// — no more "all CLI output after all messages".
enum FlowEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case toolGroup(ToolGroup)
    case cli(CliEntry)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .toolGroup(let g): return g.id
        case .cli(let c): return c.id
        }
    }
}

// Codable for a tagged union — Swift does not synthesize Codable for enums with
// associated values, so each case is boxed as { "type": …, "value": … }.
extension FlowEntry: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum CaseType: String, Codable { case message, toolGroup, cli }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(CaseType.self, forKey: .type) {
        case .message:    self = .message(try c.decode(ChatMessage.self, forKey: .value))
        case .toolGroup:  self = .toolGroup(try c.decode(ToolGroup.self, forKey: .value))
        case .cli:        self = .cli(try c.decode(CliEntry.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let m):
            try c.encode(CaseType.message, forKey: .type)
            try c.encode(m, forKey: .value)
        case .toolGroup(let g):
            try c.encode(CaseType.toolGroup, forKey: .type)
            try c.encode(g, forKey: .value)
        case .cli(let cli):
            try c.encode(CaseType.cli, forKey: .type)
            try c.encode(cli, forKey: .value)
        }
    }
}

// MARK: - Chat model

/// Pure SwiftUI replacement for the WKWebView chamber.
/// Streams RubyBridge events into published state consumed by PythiaPanel.
@MainActor
final class PythiaChatModel: ObservableObject {
    @Published var flow: [FlowEntry] = []
    @Published var companionID: String = "pythia"
    /// Companions veiled into the æther while talking to default Pythia. They
    /// answer in the chat (via `_say`) and offer follow-ups (`_suggest`), and
    /// contribute their specialist tools. Only these — the ones shown active in
    /// the bar — are hermetically active.
    @Published var activeCompanions: Set<String> = []
    @Published var busy = false
    @Published var statusText: String?
    @Published var streamingText = ""
    @Published var streamingVisible = false
    @Published var cliCwd: String = ""
        /// One-click Riss macro offered when the daemon tears the thread — transient
        /// UI state, never persisted into the flow ledger.
        @Published var recoverCard: RecoverSuggestion?
        /// Transient UI state: which individual tool chips are unfolded. Never
        /// persisted — chips start minimized every session and after each turn.
        @Published var expandedChipIDs: Set<UUID> = []
        /// Companion voices extracted from the latest reply — one-click macros that
        /// make the pantheon omnipresent instead of JSON chips.
        @Published var companionBubbles: [CompanionBubble] = []
        /// Monotonic scroll anchor: bumped whenever a fresh user/CLI turn lands so
        /// the message list always jumps to the newest chapter — even if the reader
        /// had scrolled up into older flow.
        @Published var scrollAnchor = 0

    private var history: [[String: String]] = []
    private var hasRestoredSession = false
    private var saveWorkItem: DispatchWorkItem?
    private var flowObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var recoverObserver: NSObjectProtocol?
    private var isPersisting = false
    private var boundContextRoot: String?

    var currentGlyph: String {
        pythiaCompanions.first { $0.id == companionID }?.glyph ?? "🐍"
    }

    init() {
        // Restore hermetic activation — which companions answer alongside Pythia.
        let saved = UserDefaults.standard.stringArray(forKey: "pythia.activeCompanions") ?? []
        activeCompanions = Set(saved)
        setupStreaming()
        observeFlowChanges()
        // Flush the debounced save when the app quits so the final flow state
        // survives termination.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushFlow() }
        }
        // Surface daemon recovery (timeout → kill → relaunch) instead of silently
        // continuing — the user should see *why* the æther took a breath.
        recoverObserver = NotificationCenter.default.addObserver(
            forName: RubyBridge.didRecoverNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusText = "🔁 Reconnected — daemon relaunched" }
        }
    }

    /// Restore the previous session's full flow timeline (messages, tool groups,
    /// CLI blocks, reasoning) from the per-context store, then fall back to the
    /// daemon's Chronicle for first-launch message history and cwd.
    func restoreSessionIfNeeded() {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true
        boundContextRoot = AetherContext.shared.root
        observeFlowChanges()

        // 1. Restore the persisted flow timeline (fast, local, per-context).
        if let snapshot = PythiaFlowStore.shared.load(forContext: boundContextRoot) {
            apply(snapshot: snapshot)
            statusText = "📜 Resumed \(snapshot.flow.count) flow entr\(snapshot.flow.count == 1 ? "y" : "ies")"
        }

        // 2. Fallback for a fresh context: seed cwd + bare message history from
        //    the daemon's Chronicle, woven into the flow as plain messages.
        Task { [weak self] in
            guard let self else { return }
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                let cwd = try? await RubyBridge.shared.fetchCwd()
                let restored = try? await RubyBridge.shared.fetchHistory()
                await MainActor.run {
                    if self.flow.isEmpty, let restored, !restored.isEmpty {
                        self.applyBareHistory(restored)
                        self.statusText = "📜 Resumed \(restored.count / 2) prior exchange\(restored.count / 2 == 1 ? "" : "s")"
                    }
                    if self.cliCwd.isEmpty, let cwd, !cwd.isEmpty {
                        self.cliCwd = cwd
                    }
                    self.scheduleFlowSave()
                }
            } catch {
                // Memory restore is best-effort — never block the editor on it.
            }
        }
    }

    // MARK: Persistence

    /// Persist the flow timeline for the bound context and broadcast the change
    /// so sibling windows of the same context converge.
    func persistFlow() {
        guard !isPersisting else { return }
        isPersisting = true
        defer { isPersisting = false }
        _ = PythiaFlowStore.shared.save(
            cwd: cliCwd,
            flow: flow,
            history: history,
            forContext: boundContextRoot
        )
    }

    /// Immediate, unbounced save — invoked on app termination.
    func flushFlow() {
        saveWorkItem?.cancel()
        persistFlow()
    }

    /// Called when the active project context changes. Saves the outgoing
    /// context's flow, then loads the incoming context's flow (or starts fresh).
    func contextDidChange(from oldRoot: String?, to newRoot: String?) {
        guard boundContextRoot != newRoot else { return }
        _ = PythiaFlowStore.shared.save(
            cwd: cliCwd, flow: flow, history: history,
            forContext: boundContextRoot ?? oldRoot
        )
        boundContextRoot = newRoot
        if let snapshot = PythiaFlowStore.shared.load(forContext: newRoot) {
            apply(snapshot: snapshot)
            statusText = "📜 Resumed \(snapshot.flow.count) flow entr\(snapshot.flow.count == 1 ? "y" : "ies")"
        } else {
            flow = []
            history = []
            cliCwd = ""
            statusText = nil
        }
    }

    /// Merge another context's ledger into the bound context — the drag-and-drop
    /// binding between flows. Deduplicates by entry id, persists atomically, and
    /// re-applies the merged snapshot. Returns `true` when a merge happened.
    @discardableResult
    func mergeFlow(from otherContext: String?) -> Bool {
        guard let otherContext,
              !otherContext.isEmpty,
              otherContext != boundContextRoot,
              let incoming = PythiaFlowStore.shared.load(forContext: otherContext)
        else { return false }

        let merged = PythiaFlowStore.shared.merge(incoming, intoContext: boundContextRoot)
        if merged, let snapshot = PythiaFlowStore.shared.load(forContext: boundContextRoot) {
            apply(snapshot: snapshot)
            statusText = "🔗 Merged flow from \\((otherContext as NSString).lastPathComponent)"
            return true
        }
        return false
    }

    private func observeFlowChanges() {
        guard flowObserver == nil else { return }
        flowObserver = NotificationCenter.default.addObserver(
            forName: PythiaFlowStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleRemoteFlowChange(note)
            }
        }
    }

    private func handleRemoteFlowChange(_ note: Notification) {
        guard !isPersisting else { return }
        let contextRoot = note.userInfo?["contextRoot"] as? String ?? ""
        guard contextRoot == (boundContextRoot ?? "") else { return }
        guard let snapshot = note.userInfo?["snapshot"] as? PythiaFlowStore.Snapshot else { return }
        apply(snapshot: snapshot)
    }

    private func apply(snapshot: PythiaFlowStore.Snapshot) {
        flow = snapshot.flow
        history = snapshot.history
        if !snapshot.cwd.isEmpty {
            cliCwd = snapshot.cwd
        }
    }

    private func applyBareHistory(_ entries: [[String: String]]) {
        history = entries
        flow = entries.compactMap { entry in
            guard let role = entry["role"], let content = entry["content"], !content.isEmpty else { return nil }
            let reasoning = entry["reasoning_content"]
            return .message(ChatMessage(
                role: role,
                text: content,
                glyph: role == "assistant" ? currentGlyph : "👤",
                reasoning: (reasoning?.isEmpty == false) ? reasoning : nil
            ))
        }
    }

    private func scheduleFlowSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistFlow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recoverCard = nil          // a fresh chapter closes the torn-thread offer
        companionBubbles = []      // the new turn speaks; old voices step back
        trimHistory()  // count is even here: ends on assistant
                appendMessage(ChatMessage(role: "user", text: trimmed, glyph: currentGlyph))
                history.append(["role": "user", "content": trimmed])
                scrollAnchor += 1  // a new chapter always snaps the reader to the newest line
        // Interjection while busy: the running turn is NOT aborted. The message
        // is folded into the flow and history; beginTurn() re-runs after the
        // current turn completes (git-flow merge: linear, rebased interjection).
        guard !busy else { return }
        beginTurn()
    }

    private func beginTurn() {
        busy = true
        statusText = nil
        streamingText = ""
        streamingVisible = false
        let glyph = currentGlyph
        let companion = companionID
        let sentHistoryCount = history.count
        Task { [weak self] in
            guard let self else { return }
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                let reply: OracleReply
                if companion == "pythia" {
                    reply = try await RubyBridge.shared.chatDetailed(
                        messages: history,
                        activeCompanions: Array(activeCompanions).sorted()
                    )
                } else {
                    let answer = try await RubyBridge.shared.askCompanion(name: companion, question: history.last?["content"] ?? "")
                    reply = OracleReply(text: answer, reasoningContent: nil)
                }
                let rawAnswer = reply.text ?? ""
                let finalText = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "The æther is silent." : rawAnswer
                var assistantEntry: [String: String] = ["role": "assistant", "content": finalText]
                if let rc = reply.reasoningContent, !rc.isEmpty {
                    assistantEntry["reasoning_content"] = rc
                }
                let bubbles = Self.companionBubbles(from: reply.companionSuggestions)
                await MainActor.run {
                    self.streamingVisible = false
                    self.statusText = nil
                    self.appendMessage(ChatMessage(role: "assistant", text: finalText, glyph: glyph, reasoning: reply.reasoningContent))
                    self.history.append(assistantEntry)
                    // The active pantheon answers through Pythia's turn: each
                    // `_say`/`_ask` voice lands as its own message with its glyph.
                    for say in reply.companionSays {
                        self.appendMessage(ChatMessage(role: "assistant", text: say.message, glyph: say.glyph))
                    }
                    self.companionBubbles = bubbles
                    self.trimHistory()  // count even again after assistant
                    self.collapseCompletedToolGroups()
                    self.busy = false
                }
                // Merge: interjections queued while this turn ran continue the flow.
                // This turn appended exactly one assistant entry, so anything
                // beyond +1 is a fresh user interjection waiting to be answered.
                if self.history.count > sentHistoryCount + 1 {
                    self.beginTurn()
                }
            } catch {
                await MainActor.run {
                    self.streamingVisible = false
                    self.statusText = nil
                    self.busy = false
                    self.appendMessage(ChatMessage(role: "assistant",
                                                    text: "⚠️ \(error.localizedDescription)",
                                                    glyph: glyph))
                    self.collapseCompletedToolGroups()
                }
                if self.history.count > sentHistoryCount {
                    self.beginTurn()
                }
            }
        }
    }

    /// Execute a `$`-prefixed shell command through the polymorphic CLI and
    /// weave its output into the flow as a CLI block.
    func sendCli(_ command: String) {
        var cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.hasPrefix("$") {
            cmd = String(cmd.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !cmd.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                if let result = try await RubyBridge.shared.cli(command: cmd) {
                    await MainActor.run {
                        let stdout = result["stdout"] as? String ?? ""
                        let stderr = result["stderr"] as? String ?? ""
                        let cwd = result["cwd"] as? String ?? self.cliCwd
                        self.cliCwd = cwd
                                                self.appendCli(CliEntry(
                                                    command: cmd,
                                                    output: (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines),
                                                    cwd: cwd,
                                                    exitStatus: result["exit_status"] as? Int,
                                                    done: true
                                                ))
                                                self.scrollAnchor += 1
                    }
                }
            } catch {
                                await MainActor.run {
                                    self.appendCli(CliEntry(command: cmd,
                                                            output: error.localizedDescription,
                                                            cwd: self.cliCwd,
                                                            exitStatus: 1,
                                                            done: true))
                                    self.scrollAnchor += 1
                                }
            }
        }
    }

    /// Bound conversation history to the last 40 entries. Trim points are
    /// chosen so `history.count` is always even (user/assistant pairs stay
    /// intact). Prevents unbounded memory and token growth in long sessions.
    private func trimHistory() {
        let maxEntries = 40
        if history.count > maxEntries {
            history.removeFirst(history.count - maxEntries)
        }
    }

    func selectCompanion(_ id: String) {
        companionID = id
        // Speaking to a companion directly veils it into the æther — activation
        // is implied by direct speech. Default Pythia stays the home voice.
        if id != "pythia" && !activeCompanions.contains(id) {
            activeCompanions.insert(id)
            persistActiveCompanions()
        }
        history = []  // companions are single-turn
        closeOpenToolGroup()
        streamingVisible = false
        streamingText = ""
        statusText = nil
        scheduleFlowSave()
    }

    /// Toggle a companion's hermetic activation. Active companions answer in the
    /// default Pythia chat (via `_say`/`_suggest`) and contribute their tools.
    func toggleCompanion(_ id: String) {
        if activeCompanions.contains(id) {
            activeCompanions.remove(id)
        } else {
            activeCompanions.insert(id)
        }
        persistActiveCompanions()
    }

    func isCompanionActive(_ id: String) -> Bool { activeCompanions.contains(id) }

    private func persistActiveCompanions() {
        UserDefaults.standard.set(Array(activeCompanions).sorted(), forKey: "pythia.activeCompanions")
    }

    // MARK: Riss macro & companion bubbles

    /// Re-weave the torn thread: the salvaged last intent becomes the next turn.
    func recoverLastIntent() {
        let card = recoverCard
        recoverCard = nil
        var intent = card?.lastIntent?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Swift-side timeout: the daemon died before it could salvage the Aegis
        // summary — fall back to the last user turn, the thread's true intent.
        if intent.isEmpty {
            intent = history.last(where: { $0["role"] == "user" })?["content"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !intent.isEmpty else { return }
        send(intent)
    }

    func dismissRecoverCard() {
        recoverCard = nil
    }

    /// Execute a companion bubble macro — the prompt becomes the next turn.
    func actionCompanionBubble(_ bubble: CompanionBubble) {
        companionBubbles = []
        send(bubble.prompt)
    }

    /// Map Ruby-side companion_suggestions ({glyph:, name:, prompt:}) into
    /// transient bubbles.
    private static func companionBubbles(from raw: [[String: Any]]) -> [CompanionBubble] {
        raw.compactMap { entry in
            guard let prompt = entry["prompt"] as? String, !prompt.isEmpty else { return nil }
            return CompanionBubble(
                glyph: entry["glyph"] as? String ?? "✦",
                name: entry["name"] as? String ?? "",
                prompt: prompt
            )
        }
    }

    // MARK: Streaming

    private func setupStreaming() {
        RubyBridge.shared.onStream = { [weak self] _, payload in
            guard let self, let payload else { return }
            Task { @MainActor in
                self.handleStream(payload)
            }
        }
        // Non-request daemon frames: the torn-thread offer surfaces as a
        // one-click macro instead of a dead ⚠️ bubble.
        RubyBridge.shared.onEvent = { [weak self] event in
            Task { @MainActor in
                switch event {
                case .recoverSuggestion(let suggestion):
                    self?.recoverCard = suggestion
                case .other:
                    break
                }
            }
        }
    }

    private func handleStream(_ payload: [String: Any]) {
        let kind = payload["type"] as? String ?? ""
        let data = payload["data"] as? [String: Any] ?? [:]
        let uuid = payload["uuid"] as? String
        // tool id — the model's tool_call id threaded through Artificer. Status
        // updates (file_reading, file_patching, …) merge into that one chip
        // instead of spawning a new chip per event.
        let toolId = payload["tool_id"] as? String ?? data["id"] as? String ?? data["tool_id"] as? String
        switch kind {
        case "thinking":
            statusText = "💭 \(data["message"] as? String ?? "thinking…")"
        case "thinking_complete":
            statusText = nil
        case "tool_starting", "tool_call":
            let name = (data["tool"] ?? data["name"]) as? String ?? "instrument"
            if name == "run_command" {
                // The agent's run_command merges as a CLI chip *inside* the open
                // instrumenta group — one interface, no group-tearing.
                appendCliChip(args: stringify(data["args"]), toolId: toolId)
            } else {
                appendTool(name, args: stringify(data["args"]), uuid: uuid)
            }
        case "tool_completed":
            let name = (data["tool"] ?? data["name"]) as? String ?? ""
            if name == "run_command" { break }  // completed via command_completed
            completeTool(toolId: toolId, output: stringify(data["result"]))
        case "oracle_revelation":
            // The oracle's spoken narration is a genuine assistant turn — preserve
            // it as a permanent message instead of a transient streaming bubble
            // that vanished when the final answer landed (succinct AI messages
            // were disappearing from the transcript).
            let narration = (data["raw_content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !narration.isEmpty {
                appendMessage(ChatMessage(role: "assistant", text: narration, glyph: currentGlyph))
            }
        case "oracle_conjuration_revelation":
            closeOpenToolGroup()
            streamingText = data["raw_content"] as? String ?? ""
            streamingVisible = true
        case "command_executing":
            // The agent's run_command tool — resolved into the open group's CLI
            // chip (the same unified shell block the user's `$` prompt produces).
            setCliChipCommand(data["command"] as? String ?? "", toolId: toolId)
            applyToolStatus(kind: kind, data: data, toolId: toolId)
        case "command_completed":
            if let cwd = data["cwd"] as? String, !cwd.isEmpty {
                cliCwd = cwd
            }
            completeCliChip(
                data["command"] as? String ?? "",
                output: data["content"] as? String ?? "",
                cwd: cliCwd,
                exitStatus: data["exit_status"] as? Int,
                toolId: toolId
            )
        case "system_error":
            statusText = "⚠️ \((data["message"] ?? data["error"]) as? String ?? "system error")"
        default:
            if Self.toolStatusKinds.contains(kind) {
                mergeToolStatus(kind: kind, data: data, uuid: uuid)
            }
        }
    }

    // MARK: Flow weaving

    /// Append a message to the unified flow, closing any open tool run first so
    /// interleaved text cleanly separates instrumenta groups.
    private func appendMessage(_ message: ChatMessage) {
        closeOpenToolGroup()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.message(message))
        }
        scheduleFlowSave()
    }

    /// Append a top-level CLI block (the user's `$` prompt) — always a group
    /// boundary for the preceding tool run. The agent's run_command instead
    /// merges as a CLI chip *inside* the group (see appendCliChip).
    private func appendCli(_ entry: CliEntry) {
        closeOpenToolGroup()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.cli(entry))
        }
        scheduleFlowSave()
    }

    /// Merge an instrument call into the trailing open group when calls are
    /// consecutive; otherwise open a fresh collapsible cluster.
    private func appendTool(_ name: String, args: String = "", uuid: String? = nil) {
        appendChip(ToolChip(name: name, args: args, done: false, horologiumID: uuid))
    }

    /// The agent's run_command — a CLI chip inside the open group.
    private func appendCliChip(args: String = "", toolId: String? = nil) {
        var chip = ToolChip(kind: .cli, name: "run_command", args: args, done: false, command: "", cwd: cliCwd)
        chip.toolId = toolId
        appendChip(chip)
    }

    private func appendChip(_ chip: ToolChip) {
        if let idx = openToolGroupIndex(),
           case .toolGroup(let group) = flow[idx] {
            var g = group
            g.tools.append(chip)
            flow[idx] = .toolGroup(g)
        } else {
            var g = ToolGroup()
            g.tools.append(chip)
            flow.append(.toolGroup(g))
        }
        scheduleFlowSave()
    }

    private func openToolGroupIndex() -> Int? {
        flow.lastIndex(where: { if case .toolGroup(let g) = $0 { return !g.closed } else { return false } })
    }

    /// Attach the real command to the open CLI chip (or create one if the
    /// tool_starting frame was missed).
    private func setCliChipCommand(_ cmd: String, toolId: String? = nil) {
        guard let idx = openToolGroupIndex(),
              case .toolGroup(let group) = flow[idx] else {
            appendCliChip(toolId: toolId)
            return
        }
        var g = group
        if let chipIdx = g.tools.lastIndex(where: { $0.kind == .cli && !$0.done && (toolId == nil || $0.toolId == toolId) }) {
            g.tools[chipIdx].command = cmd
            flow[idx] = .toolGroup(g)
            scheduleFlowSave()
        } else {
            appendCliChip(toolId: toolId)
        }
    }

    /// Fill the open CLI chip with command output, cwd and exit status.
    private func completeCliChip(_ cmd: String, output: String, cwd: String, exitStatus: Int?, toolId: String? = nil) {
        guard let idx = openToolGroupIndex(),
              case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        if let chipIdx = g.tools.lastIndex(where: { $0.kind == .cli && !$0.done && (toolId == nil || $0.toolId == toolId) }) {
            if !cmd.isEmpty { g.tools[chipIdx].command = cmd }
            g.tools[chipIdx].output = output
            g.tools[chipIdx].cwd = cwd
            g.tools[chipIdx].exitStatus = exitStatus
            g.tools[chipIdx].done = true
            g.tools[chipIdx].status = nil
            flow[idx] = .toolGroup(g)
            scheduleFlowSave()
        }
    }

    /// Mark the newest unfinished *instrument* chip as completed. CLI chips are
    /// completed via command_completed, not here.
    private func completeTool(toolId: String? = nil, output: String) {
        guard let idx = flow.lastIndex(where: { if case .toolGroup = $0 { return true } else { return false } }) else { return }
        guard case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        var chipIdx: Int? = nil
        if let toolId {
            chipIdx = g.tools.lastIndex(where: { $0.toolId == toolId })
        }
        if chipIdx == nil {
            chipIdx = g.tools.lastIndex(where: { $0.kind == .instrument && !$0.done })
        }
        guard let ci = chipIdx else { return }
        g.tools[ci].done = true
        g.tools[ci].output = output
        g.tools[ci].status = nil
        flow[idx] = .toolGroup(g)
        scheduleFlowSave()
    }

    /// Horologium status kinds that belong to a specific instrument invocation —
    /// they carry the same uuid as their `tool_starting` envelope and merge into
    /// that single chip instead of each spawning a new flow entry.
    private static let toolStatusKinds: Set<String> = [
        "file_reading", "file_read_complete", "file_read_fail",
        "file_creating", "file_created", "temp_file_created",
        "file_patching", "file_patched", "file_patched_fail",
        "file_renaming", "file_renamed",
        "undo_completed", "undo_failed",
        "symbolic_patch_start", "symbolic_patch_complete", "symbolic_patch_fail",
        "memory_storing", "memory_stored", "note_added", "note_removed", "note_updated",
        "memory_searching", "memory_found", "notes_recalled",
        "file_overview",
        "screenshot_capturing", "screenshot_captured", "screenshot_failed",
    ]

    /// Merge a granular Horologium frame into the in-flight instrument chip it
    /// belongs to. Serial execution means there is at most one open instrument at
    /// a time; the uuid is recorded so later frames for the same call find the
    /// same chip. The group's `expanded` state is deliberately left untouched —
    /// an update must never yank a chip the user unfolded back shut.
    private func mergeToolStatus(kind: String, data: [String: Any], uuid: String?) {
        guard let (gIdx, cIdx) = openInstrumentChipLocation(),
              case .toolGroup(let group) = flow[gIdx] else { return }
        var g = group
        var chip = g.tools[cIdx]
        if let uuid, !uuid.isEmpty { chip.horologiumID = uuid }
        let (status, detail) = Self.toolStatusText(kind: kind, data: data)
        if let status { chip.status = status }
        if let detail { chip.detail = detail }
        if let rawMessage = data["message"] as? String, !rawMessage.isEmpty {
            chip.message = Self.plainTextFromHTML(rawMessage)
        }
        g.tools[cIdx] = chip
        flow[gIdx] = .toolGroup(g)
        scheduleFlowSave()
    }

    private func openInstrumentChipLocation() -> (group: Int, chip: Int)? {
        for gIdx in flow.indices.reversed() {
            guard case .toolGroup(let group) = flow[gIdx] else { continue }
            if let cIdx = group.tools.lastIndex(where: { $0.kind == .instrument && !$0.done }) {
                return (gIdx, cIdx)
            }
        }
        return nil
    }

    /// Translate a Horologium status kind + data into a one-line live status
    /// (for the minified summary) and a richer detail line (for the expanded view).
    private static func toolStatusText(kind: String, data: [String: Any]) -> (status: String?, detail: String?) {
        let path = data["path"] as? String
        let short = path.map { ($0 as NSString).lastPathComponent }
        let range = data["range"] as? [Int]
        let bytes = (data["bytes_read"] as? Int) ?? (data["bytes"] as? Int)

        switch kind {
        case "file_reading":
            return (short.map { "Liest \($0)…" } ?? "Liest…", detailLine(path: path, range: range))
        case "file_read_complete":
            return (short.map { "Gelesen \($0)" } ?? "Gelesen", detailLine(path: path, range: range, bytes: bytes))
        case "file_read_fail":
            return ("Lesefehler", short)
        case "file_creating":
            return (short.map { "Erzeugt \($0)…" } ?? "Erzeugt…", path)
        case "file_created":
            return (short.map { "Erzeugt \($0)" } ?? "Erzeugt", detailLine(path: path, bytes: bytes))
        case "temp_file_created":
            return (short.map { "Temp \($0)" } ?? "Temp-Datei", path)
        case "file_patching":
            return ("Patcht \(short ?? "Datei")…", (data["diff_lines"] as? Int).map { "\($0) Diff-Zeilen" })
        case "file_patched":
            return ("Gepatcht", path)
        case "file_patched_fail":
            return ("Patch fehlgeschlagen", short)
        case "file_renaming":
            return ("Benennt um…", path)
        case "file_renamed":
            return ("Umbenannt", path)
        case "undo_completed":
            return ("Rückgängig vollzogen", path)
        case "undo_failed":
            return ("Rückgängig fehlgeschlagen", path)
        case "symbolic_patch_start":
            return ("Symbol-Patch…", path)
        case "symbolic_patch_complete":
            return ("Symbol-Patch vollzogen", path)
        case "symbolic_patch_fail":
            return ("Symbol-Patch fehlgeschlagen", path)
        case "memory_storing", "note_added", "note_updated":
            return ("Speichert Erinnerung…", nil)
        case "memory_stored":
            return ("Erinnerung gespeichert", nil)
        case "note_removed":
            return ("Notiz gelöscht", nil)
        case "memory_searching", "notes_recalled":
            return ("Ruft Erinnerung ab…", nil)
        case "memory_found":
            return ("Erinnerung gefunden", nil)
        case "file_overview":
            return ("Überblickt…", path)
        case "screenshot_capturing":
            return ("Blickt…", data["mode"] as? String)
        case "screenshot_captured":
            return ("Blick festgehalten", data["path"] as? String)
        case "screenshot_failed":
            return ("Blick fehlgeschlagen", data["error"] as? String)
        default:
            return (nil, nil)
        }
    }

    private static func detailLine(path: String?, range: [Int]? = nil, bytes: Int? = nil) -> String? {
        var parts: [String] = []
        if let path { parts.append(path) }
        if let range, range.count == 2 { parts.append("Zeilen \(range[0])–\(range[1])") }
        if let bytes { parts.append("\(bytes) Bytes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Merge a horologium status update into the matching open chip. The update
    /// only changes the chip's live status line — it never toggles the group's
    /// expanded state, so an expanded view stays expanded while a tool streams.
    private func applyToolStatus(kind: String, data: [String: Any], toolId: String?) {
        guard let status = InstrumentaStatus.text(for: kind, data: data) else { return }
        guard let idx = openToolGroupIndex(),
              case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        var chipIdx: Int? = nil
        if let toolId {
            chipIdx = g.tools.lastIndex(where: { $0.toolId == toolId })
        }
        if chipIdx == nil {
            chipIdx = g.tools.lastIndex(where: { !$0.done })
        }
        guard let ci = chipIdx else { return }
        g.tools[ci].status = status
        flow[idx] = .toolGroup(g)
        scheduleFlowSave()
    }

    /// Coerce a Ruby-side value into a display string for tool args/output.
    /// Structured values become readable JSON (not Swift's `["key": …]` dump),
    /// so Mnemosyne & co. can be rendered as *meaning*, not a debug fragment.
    private func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    /// Collapse a Ruby-side `Scriptorium.html` message into plain text for the
    /// minimized line — strips `<file>`/`<a>`/`<strong>` tags and decodes the
    /// few entities Redcarpet escapes, preserving the human meaning (path,
    /// byte count, line range) without the markup.
    private static func plainTextFromHTML(_ html: String) -> String {
        var s = html
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Close the trailing open tool run so later events start a new group.
    private func closeOpenToolGroup() {
        guard let idx = flow.lastIndex(where: { if case .toolGroup(let g) = $0 { return !g.closed } else { return false } }) else { return }
        guard case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        g.closed = true
        flow[idx] = .toolGroup(g)
        scheduleFlowSave()
    }

    /// Fold away every completed (closed) tool group once a turn finishes —
    /// finished instrumenta clusters recede quietly, in-flight ones stay open.
    private func collapseCompletedToolGroups() {
        withAnimation(.easeInOut(duration: 0.28)) {
            for idx in flow.indices {
                guard case .toolGroup(let group) = flow[idx], group.closed else { continue }
                // Every completed cluster recedes quietly to its one-line summary —
                // the user can click to unfold the chips (and their output) again.
                var g = group
                g.expanded = false
                flow[idx] = .toolGroup(g)
            }
            // Individual chips fold with their cluster — every turn reopens to a
            // clean, minimized instrumenta ledger.
            expandedChipIDs.removeAll()
        }
        scheduleFlowSave()
    }

    /// Toggle a tool group's collapsed state in place.
    func toggleToolGroup(_ id: UUID) {
        guard let idx = flow.firstIndex(where: { if case .toolGroup(let g) = $0 { return g.id == id } else { return false } }) else { return }
        guard case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        g.expanded.toggle()
        flow[idx] = .toolGroup(g)
        scheduleFlowSave()
    }

    /// Toggle a single tool chip's minimized/expanded state inside a group.
    func toggleToolChip(_ id: UUID) {
        if expandedChipIDs.contains(id) {
            expandedChipIDs.remove(id)
        } else {
            expandedChipIDs.insert(id)
        }
    }
}

// MARK: - Pythia panel

struct PythiaPanel: View {
    @ObservedObject var model: PythiaChatModel
    @ObservedObject private var aetherContext = AetherContext.shared
    @State private var themeRevision = 0

    /// The active theme's chamber palette — mirrors the code editor's chrome.
    private var palette: PythiaPalette { ThemeRegistry.shared.current.pythia }

    var body: some View {
        let palette = self.palette
        let _ = themeRevision
        MessageList(model: model)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .safeAreaBar(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            HStack(spacing: 6) {
              CompanionPicker(model: model)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 56)  // window chrome clearance
            .padding(.bottom, 6)

            if aetherContext.root != nil {
                HStack(spacing: 6) {
                    ContextPill(context: aetherContext)
                    Spacer(minLength: 0)
                    debugGlyphButton
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            Divider().opacity(0.4)

          }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            if let card = model.recoverCard {
                RecoverCardView(card: card, model: model)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !model.companionBubbles.isEmpty {
                CompanionBubbleBar(model: model)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            StreamingFooter(model: model)
                .padding(.horizontal, 10)
                .padding(.top, 4)

            InputBar(model: model)
                .padding(10)
          }
          .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.recoverCard == nil)
          .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.companionBubbles)
        }
        .onAppear {
            model.restoreSessionIfNeeded()
        }
        .onChange(of: aetherContext.root) { oldRoot, newRoot in
            model.contextDidChange(from: oldRoot, to: newRoot)
        }
        .environment(\.pythiaPalette, palette)
        .tint(palette.accentColor)
        .onReceive(NotificationCenter.default.publisher(for: ThemeSettings.didChangeNotification)) { _ in
            themeRevision += 1
        }
    }

    /// Liquid-glass glyph button toggling the Æther Debug window (daemon logs)
    /// — hidden chrome, revealed only when a project context breathes.
    private var debugGlyphButton: some View {
        Button {
            AetherDebugWindowController.shared.toggle()
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foregroundColor)
        .help("Show Æther Debug")
    }

}

// MARK: - Context pill

/// The active project's identity — a quiet glyph + name that lets the window
/// advertise *which* æther it is currently breathing. "ICH bin der ÆTHER."
private struct ContextPill: View {
    @ObservedObject var context: AetherContext
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            Text("◈")
                .font(.system(size: 10))
                .foregroundStyle(context.configPath != nil ? palette.accentColor : Color.secondary)
            Text(context.name ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        .help(context.root ?? "No project context")
    }
}

// MARK: - Companion picker

private struct CompanionPicker: View {
    @ObservedObject var model: PythiaChatModel
    @ObservedObject private var bridge = RubyBridge.shared
    @Environment(\.pythiaPalette) private var palette

    /// The pantheon as the daemon knows it — one roster, two worlds. Falls back
    /// to the local copy until the first `ready` frame arrives; Pythia herself
    /// is always first (the wire roster carries only the companions).
    private var companions: [Companion] {
        var list = bridge.companionRoster.map {
            Companion(id: $0.key, glyph: $0.glyph, label: $0.name)
        }
        if !list.contains(where: { $0.id == "pythia" }) {
            list.insert(Companion(id: "pythia", glyph: "🐍", label: "Pythia"), at: 0)
        }
        return list.isEmpty ? pythiaCompanions : list
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(companions) { companion in
                    pickerButton(for: companion)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// One glyph, two gestures: a click toggles hermetic activation (the voice
    /// joins/leaves the default Pythia chat), a right-click speaks to the
    /// companion directly. Pythia herself is the immutable home voice.
    @ViewBuilder
    private func pickerButton(for companion: Companion) -> some View {
        let isPythia = companion.id == "pythia"
        let isDirect = model.companionID == companion.id
        let isActive = isPythia || model.isCompanionActive(companion.id)

        Button {
            if isPythia {
                model.selectCompanion("pythia")
            } else {
                model.toggleCompanion(companion.id)
            }
        } label: {
            Text(companion.glyph)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isActive ? 1.0 : 0.45)
        .background(
            isDirect ? AnyShapeStyle(.regularMaterial)
                     : (isActive ? AnyShapeStyle(palette.accentColor.opacity(0.16))
                                 : AnyShapeStyle(.clear)),
            in: Circle()
        )
        .overlay(
            Circle().strokeBorder(
                isDirect ? palette.accentColor.opacity(0.95)
                         : (isActive ? palette.accentColor.opacity(0.5) : .white.opacity(0.10)),
                lineWidth: isDirect ? 1.2 : 0.75
            )
        )
        .scaleEffect(isDirect ? 1.08 : (isActive ? 1.03 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isDirect)
        .help(helpText(for: companion, isPythia: isPythia, isActive: isActive, isDirect: isDirect))
        .contextMenu {
            if !isPythia {
                Button(isDirect ? "✓ \(companion.label)" : "Mit \(companion.label) sprechen") {
                    model.selectCompanion(companion.id)
                }
                Divider()
                Button(isActive ? "Deaktivieren" : "Aktivieren") {
                    model.toggleCompanion(companion.id)
                }
            }
        }
    }

    private func helpText(for companion: Companion, isPythia: Bool, isActive: Bool, isDirect: Bool) -> String {
        if isPythia {
            return isDirect ? "Pythia — Standard-Orakel" : "Zu Pythia zurückkehren"
        }
        let state = isActive ? "aktiv" : "inaktiv"
        let voice = isDirect ? " · du sprichst direkt" : ""
        return "\(companion.label) (\(state))\(voice)\nKlick: aktivieren/deaktivieren · Rechtsklick: direkt sprechen"
    }
}

// MARK: - CLI block

/// The unified shell block woven into the flow — produced both by the user's `$`
/// prompt and by the agent's `run_command` tool. Two hands, one interface.
private struct CliBlock: View {
    let entry: CliEntry
    @Environment(\.pythiaPalette) private var palette
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("$")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accentColor)
                    Text(highlightCode(entry.command, language: "shell"))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if entry.done {
                        Image(systemName: entry.exitStatus == 0 ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(entry.exitStatus == 0 ? Color.secondary : Color.red.opacity(0.8))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !entry.output.isEmpty {
                CliOutputPane(text: entry.output)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Streaming footer


private struct MessageList: View {
    @ObservedObject var model: PythiaChatModel
    @State private var breathing = false
    /// True when the reader is parked at the live edge — autoscroll may follow.
    @State private var isAtBottom = true

    /// How far the true bottom may drift below the visible edge before we
    /// detach and surface the "jump to bottom" arrow.
    private let proximityThreshold: CGFloat = 48

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    if model.flow.isEmpty && !model.streamingVisible {
                        emptyState
                    }
                    ForEach(model.flow) { entry in
                        switch entry {
                        case .message(let message):
                            MessageRow(message: message)
                        case .toolGroup(let group):
                            ToolGroupView(model: model, group: group)
                        case .cli(let cli):
                            CliBlock(entry: cli)
                        }
                    }
                    if model.streamingVisible {
                        // Plain text while streaming: AttributedString(markdown:)
                        // re-parses the whole buffer on every token, which
                        // spikes CPU for long oracle revelations.
                        MessageRow(message: ChatMessage(role: "assistant",
                                                        text: model.streamingText,
                                                        glyph: model.currentGlyph),
                                   plain: true)
                            .opacity(0.8)
                            .id("stream")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Distance from the visible bottom edge to the content's true
                // bottom. Within the threshold → attached (arrow hidden).
                let distanceToBottom = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return distanceToBottom <= proximityThreshold
            } action: { _, atBottom in
                if isAtBottom != atBottom {
                    isAtBottom = atBottom
                }
            }
            .onChange(of: model.scrollAnchor) { _, _ in
                // A fresh user/CLI turn always wins the reader's attention.
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                isAtBottom = true
            }
            .onChange(of: model.flow) { _, _ in
                followLiveEdge(proxy)
            }
            .onChange(of: model.streamingText) { _, _ in
                followLiveEdge(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    jumpToBottomButton(proxy)
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isAtBottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(model.currentGlyph)
                .font(.system(size: 30))
                .scaleEffect(breathing ? 1.05 : 1.0)
                .opacity(breathing ? 0.72 : 1.0)
            Text("Ask Pythia, or summon a companion to consult the æther.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    /// Follow the live edge while it grows, but only if the reader is already
    /// parked at the bottom. Once they scroll up, the thread belongs to them.
    private func followLiveEdge(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            isAtBottom = true
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Jump to the newest line")
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    var plain = false
    @State private var showThinking = false

    private var isUser: Bool { message.role == "user" }
    private var bubbleMaterial: Material { isUser ? .thinMaterial : .regularMaterial }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if isUser {
                Spacer(minLength: 24)
                bubble
                    .frame(maxWidth: 300, alignment: .trailing)
            } else {
                Text(message.glyph)
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 6) {
                    if let reasoning = message.reasoning, !reasoning.isEmpty, !plain {
                        ThinkingBlock(text: reasoning, isExpanded: $showThinking)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    bubble
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var bubble: some View {
        MarkdownBody(text: message.text, plain: plain)
            .environment(\.openURL, OpenURLAction { url in
                // AI-authored markdown may embed arbitrary URL schemes;
                // allow only http/https to leave the app.
                (url.scheme == "https" || url.scheme == "http") ? .systemAction : .handled
            })
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(bubbleMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(isUser ? 0.14 : 0.10), lineWidth: 0.5)
            )
    }
}

// MARK: - Thinking block

/// Collapsible "Gedanke" — the model's reasoning_content, rendered with the
/// same MarkdownBody as the answer (HTML-aware) instead of being discarded.
private struct ThinkingBlock: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("💭 Gedanke")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownBody(text: text)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - Streaming footer

private struct StreamingFooter: View {
    @ObservedObject var model: PythiaChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.cliCwd.isEmpty {
                CwdStatus(cwd: model.cliCwd)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let status = model.statusText {
                Text(renderInline(status))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.statusText)
        .animation(.easeInOut(duration: 0.18), value: model.cliCwd)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The polymorphic shell's current working directory — the quiet status line
/// anchoring the CLI to the same filesystem truth the agent inhabits.
private struct CwdStatus: View {
    let cwd: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 9))
            Text(cwd)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .help(cwd)
    }
}

/// A collapsible cluster of *consecutive* instrumenta calls, rendered inline
/// at its chronological position in the flow. Independent from any footer.
private struct ToolGroupView: View {
    @ObservedObject var model: PythiaChatModel
    let group: ToolGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    model.toggleToolGroup(group.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(group.expanded ? 90 : 0))
                    if group.expanded {
                        Text(group.tools.count == 1 ? "1 Instrument" : "\(group.tools.count) Instrumente")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    } else {
                        // Collapsed: only the *last* tool call — a quiet
                        // one-liner naming the newest action, not a row of chips.
                        if group.tools.count > 1 {
                            Text("\(group.tools.count) ·")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if let last = group.tools.last {
                            MinifiedInstrumentLabel(chip: last)
                        }
                    }
                    Spacer(minLength: 0)
                    if group.allDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if group.expanded {
                ForEach(group.tools) { chip in
                    ToolChipRow(model: model, chip: chip)
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: group.expanded)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// Minified rendering of a single instrument — the original horologium message
/// (or a synthesized fallback) as a compact, information-rich line: path, byte
/// count and line range, not a bare glyph + verb.
private struct MinifiedInstrumentLabel: View {
    let chip: ToolChip

    var body: some View {
        Text(chip.minifiedSummary)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
    }
}

/// Human status line for a horologium event, so an in-flight instrumenta chip
/// can show *what it is doing right now* (not a debug param dump). Unknown kinds
/// return nil so unrelated events never touch a chip.
struct InstrumentaStatus {
    static func text(for kind: String, data: [String: Any]) -> String? {
        let path = data["path"] as? String
        let query = data["query"] as? String
        let file = path.map { ($0 as NSString).lastPathComponent }
        switch kind {
        case "file_reading": return file.map { "liest \($0)" } ?? "liest…"
        case "file_read_complete": return "gelesen"
        case "file_read_fail": return "Lesefehler"
        case "file_creating": return file.map { "erzeugt \($0)" } ?? "erzeugt…"
        case "file_created": return "erzeugt"
        case "temp_file_created": return "temp \(file ?? "datei")"
        case "file_patching": return file.map { "patcht \($0)" } ?? "patcht…"
        case "file_patched": return "gepatcht"
        case "file_patched_fail": return "Patchfehler"
        case "file_renaming": return file.map { "benennt \($0) um" } ?? "benennt um…"
        case "file_renamed": return "umbenannt"
        case "symbolic_patch_start": return "symbolischer Patch…"
        case "symbolic_patch_complete": return "symbolisch gepatcht"
        case "symbolic_patch_fail", "symbolic_patch_failed": return "Symbol-Patchfehler"
        case "undo_patch": return "rückgängig…"
        case "memory_searching": return query.map { "sucht „\($0)“" } ?? "sucht…"
        case "memory_found": return "gefunden"
        case "memory_storing": return "speichert…"
        case "memory_stored": return "gespeichert"
        case "note_added": return "Notiz angelegt"
        case "note_removed": return "Notiz entfernt"
        case "note_updated": return "Notiz aktualisiert"
        case "notes_recalled": return "erinnert"
        case "file_overview": return "Übersicht…"
        case "aegis_unveiled": return "Aegis entschleiert"
        case "screenshot_capturing": return "Screenshot…"
        case "screenshot_captured": return "Screenshot"
        case "screenshot_failed": return "Screenshot-Fehler"
        case "command_executing": return "führt aus…"
        case "command_completed": return "fertig"
        case "ask_user": return "fragt…"
        case "peer_drift": return "Drift erkannt"
        case "self_control_danger": return "Selbstkontrolle"
        default: return nil
        }
    }
}

// MARK: - Instrumenta semantics

/// Hermetic glyph + label + tint per instrument domain, so a tool call reads as
/// *meaning* (what it does) rather than a debug param dump.
struct InstrumentaSemantics {
    let glyph: String
    let label: String
    let tint: Color

    static func forTool(_ name: String) -> InstrumentaSemantics {
        switch name {
        case "read_file", "file_overview":
            return InstrumentaSemantics(glyph: "🌘", label: "Liest", tint: .cyan)
        case "create_file":
            return InstrumentaSemantics(glyph: "✒️", label: "Erzeugt", tint: .orange)
        case "rename_file":
            return InstrumentaSemantics(glyph: "🔀", label: "Benennt", tint: .orange)
        case "temp_create_file":
            return InstrumentaSemantics(glyph: "🫧", label: "Temp-Datei", tint: .orange)
        case "patch_file":
            return InstrumentaSemantics(glyph: "🩹", label: "Patch", tint: .orange)
        case "undo_patch":
            return InstrumentaSemantics(glyph: "↩️", label: "Rückgängig", tint: .orange)
        case "symbolic_patch_file":
            return InstrumentaSemantics(glyph: "🔣", label: "Symbol-Patch", tint: .orange)
        case "remember":
            return InstrumentaSemantics(glyph: "🧠", label: "Erinnert", tint: .purple)
        case "remove_note":
            return InstrumentaSemantics(glyph: "🗑️", label: "Löscht", tint: .purple)
        case "recall_notes", "recall_history", "get_note":
            return InstrumentaSemantics(glyph: "🔎", label: "Ruft ab", tint: .purple)
        case "metempsychosis":
            return InstrumentaSemantics(glyph: "🦋", label: "Wanderung", tint: .indigo)
        case "aegis":
            return InstrumentaSemantics(glyph: "🛡️", label: "Aegis", tint: .indigo)
        case "create_task", "execute_task", "update_task", "evaluate_task", "list_tasks", "remove_task":
            return InstrumentaSemantics(glyph: "⚗️", label: "Aufgabe", tint: .pink)
        case "oracle_conjuration":
            return InstrumentaSemantics(glyph: "🔮", label: "Beschwörung", tint: .indigo)
        case "take_screenshot":
            return InstrumentaSemantics(glyph: "👁️", label: "Blick", tint: .gray)
        case "tell_user", "ask_user":
            return InstrumentaSemantics(glyph: "🗣️", label: "Spricht", tint: .teal)
        case "run_command":
            return InstrumentaSemantics(glyph: "🐚", label: "Shell", tint: .mint)
        default:
            if name.hasSuffix("_suggest") || name.hasSuffix("_say")
                || name.hasSuffix("_commit") || name.hasSuffix("_ask") {
                return InstrumentaSemantics(glyph: "🗣️", label: "Gefährte", tint: .mint)
            }
            return InstrumentaSemantics(glyph: "🔧", label: name, tint: .secondary)
        }
    }
}

/// One chip inside a tool group — either a semantic instrument or a CLI block
/// (the agent's run_command). Each carries its own meaning, not raw JSON.
private struct ToolChipRow: View {
    @ObservedObject var model: PythiaChatModel
    let chip: ToolChip
    private var sem: InstrumentaSemantics { InstrumentaSemantics.forTool(chip.name) }
    private var isExpanded: Bool { model.expandedChipIDs.contains(chip.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    model.toggleToolChip(chip.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(chip.minifiedSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if chip.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(sem.tint)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(sem.tint.opacity(chip.done ? 0.15 : 0.35), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if isExpanded {
                chipBody
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isExpanded)
    }

    @ViewBuilder
    private var chipBody: some View {
        if chip.kind == .cli {
            CliChipView(chip: chip)
        } else if MnemosyneTool.isMnemosyne(chip.name) {
            MnemosyneCauldronView(chip: chip)
        } else if FileOverviewTool.isFileOverview(chip.name) {
            FileOverviewView(chip: chip)
        } else if FileInstrumentTool.isReadFile(chip.name) {
            ReadFileView(chip: chip)
        } else if FileInstrumentTool.isPatchFile(chip.name) {
            PatchFileView(chip: chip)
        } else if FileInstrumentTool.isCreateFile(chip.name) {
            CreateFileView(chip: chip)
        } else if FileInstrumentTool.isRenameFile(chip.name) {
            RenameFileView(chip: chip)
        } else if FileInstrumentTool.isUndoPatch(chip.name) {
            UndoPatchView(chip: chip)
        } else {
            InstrumentChipView(chip: chip)
        }
    }
}

private struct InstrumentChipView: View {
    let chip: ToolChip
    private var sem: InstrumentaSemantics { InstrumentaSemantics.forTool(chip.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !chip.args.isEmpty {
                Text(chip.args)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if let status = chip.status, !status.isEmpty, !chip.done {
                Text(status)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(sem.tint.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if let detail = chip.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            if !chip.output.isEmpty {
                Text(chip.output)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(sem.tint.opacity(chip.done ? 0.15 : 0.35), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Scrollable command output with progressive blur at both scroll edges and a
/// frosted bed behind the monospaced text — a shell result reads as a glowing
/// fragment, not a raw dump.
private struct CliOutputPane: View {
    let text: String
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        ScrollView(.vertical) {
            Text(highlightCode(text, language: "shell"))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 180)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background(palette.codeBackgroundColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(palette.shineColor.opacity(0.22), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// The agent's run_command rendered as the unified shell block — but *inside*
/// the instrumenta group, so consecutive tool calls stay one collapsible unit.
private struct CliChipView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("$")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accentColor)
                    Text(highlightCode(chip.command.isEmpty ? "run_command" : chip.command, language: "shell"))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if chip.done {
                        Image(systemName: chip.exitStatus == 0 ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(chip.exitStatus == 0 ? Color.secondary : Color.red.opacity(0.8))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !chip.output.isEmpty {
                CliOutputPane(text: chip.output)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(palette.shineColor.opacity(0.30), lineWidth: 0.5)
        )
        .shadow(color: palette.shineColor.opacity(0.10), radius: 5, y: 1)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Riss recovery card

/// The one-click re-weave macro: when the daemon's worker tears the thread,
/// the companion becomes the next chapter's beginning instead of a dead error.
private struct RecoverCardView: View {
    let card: RecoverSuggestion
    @ObservedObject var model: PythiaChatModel
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(card.glyph)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.prompt)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                if let intent = card.lastIntent, !intent.isEmpty {
                    Text(intent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.recoverLastIntent()
            } label: {
                Text("Weiterweben")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(.black)
                    .background(palette.accentColor, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Letzte Absicht erneut ansetzen")
            Button {
                model.dismissRecoverCard()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Verwerfen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.accentColor.opacity(0.35), lineWidth: 0.75)
        )
        .shadow(color: palette.shineColor.opacity(0.22), radius: 6, y: 2)
    }
}

// MARK: - Companion speech bubbles

/// Omnipresent companion voices: the reply's extracted suggestions become
/// one-click macros — the pantheon speaks through the UI, not JSON chips.
/// Rendered as true speech bubbles in a wrapping flow: each bubble hugs its
/// prompt (short → compact, long → multi-line), anchors its voice to the
/// speaker's glyph via a downward tail, and is fully clickable with hover lift.
private struct CompanionBubbleBar: View {
    @ObservedObject var model: PythiaChatModel
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            CompanionFlowLayout(spacing: 7, maxItemWidth: 236) {
                ForEach(model.companionBubbles) { bubble in
                    CompanionSpeechBubble(bubble: bubble, palette: palette) {
                        model.actionCompanionBubble(bubble)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }
}

/// A single companion suggestion as a real speech bubble — glyph + name in a
/// small header, the prompt as a multi-line body that wraps to the bubble's
/// max width, and a tail pointing down toward the speaking companion.
private struct CompanionSpeechBubble: View {
    let bubble: CompanionBubble
    let palette: PythiaPalette
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(bubble.glyph)
                        .font(.system(size: 11))
                    if !bubble.name.isEmpty {
                        Text(bubble.name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.accentColor)
                    }
                }
                Text(bubble.prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 11)
            .padding(.top, 7)
            .padding(.bottom, 12)
            .frame(maxWidth: 236, alignment: .leading)
            .background(.regularMaterial, in: SpeechBubbleShape())
            .overlay(
                SpeechBubbleShape()
                    .stroke(.white.opacity(hovered ? 0.24 : 0.11), lineWidth: 0.5)
            )
            .contentShape(SpeechBubbleShape())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.02 : 1.0)
        .shadow(color: palette.shineColor.opacity(hovered ? 0.30 : 0.14), radius: hovered ? 7 : 4, y: 2)
        .animation(.easeInOut(duration: 0.16), value: hovered)
        .onHover { hovered = $0 }
        .help(bubble.prompt)
    }
}

/// A rounded speech bubble with a tail pointing down at the lower-left — the
/// companion "speaks" from below, and the tail anchors the voice to its glyph.
private struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 10
    var tailSize: CGSize = CGSize(width: 9, height: 7)
    var tailOffset: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let tail = tailSize
        let bubbleRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height - tail.height
        )
        var path = Path()
        path.addRoundedRect(in: bubbleRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        let baseY = bubbleRect.maxY
        let tipX = rect.minX + tailOffset + tail.width * 0.5
        path.move(to: CGPoint(x: rect.minX + tailOffset, y: baseY))
        path.addLine(to: CGPoint(x: rect.minX + tailOffset + tail.width, y: baseY))
        path.addLine(to: CGPoint(x: tipX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Wraps child views into multiple left-aligned rows, proposing each child a
/// bounded width so text wraps — the pantheon "talks" in a flowing paragraph
/// of bubbles rather than a single endless horizontal line.
private struct CompanionFlowLayout: Layout {
    var spacing: CGFloat = 7
    var maxItemWidth: CGFloat = 236

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? maxItemWidth
        let rows = arrange(subviews: subviews, containerWidth: containerWidth)
        return CGSize(width: containerWidth, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let containerWidth = proposal.width ?? maxItemWidth
        let rows = arrange(subviews: subviews, containerWidth: containerWidth)
        var y = bounds.minY
        for row in rows.rows {
            var x = bounds.minX
            var rowHeight: CGFloat = 0
            for item in row.items {
                rowHeight = max(rowHeight, item.size.height)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
    }

    private struct Arrangement {
        var rows: [Row] = []
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, containerWidth: CGFloat) -> Arrangement {
        let itemMax = containerWidth > 0 ? min(maxItemWidth, containerWidth) : maxItemWidth
        var arrangement = Arrangement()
        var row = Row()
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: itemMax, height: nil))
            if !row.items.isEmpty && rowWidth + size.width + spacing > containerWidth {
                arrangement.rows.append(row)
                arrangement.height += rowHeight + spacing
                row = Row()
                rowWidth = 0
                rowHeight = 0
            }
            let advance = size.width + (row.items.isEmpty ? 0 : spacing)
            row.items.append((index: index, size: size))
            rowWidth += advance
            rowHeight = max(rowHeight, size.height)
        }
        if !row.items.isEmpty {
            arrangement.rows.append(row)
            arrangement.height += rowHeight
        }
        return arrangement
    }
}

// MARK: - Input bar

private struct InputBar: View {
    @ObservedObject var model: PythiaChatModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.pythiaPalette) private var palette

    /// `$` as the first character opens the polymorphic Pythia CLI: the same
    /// shell the agent's `run_command` tool inhabits. One interface, two hands.
    private var cliMode: Bool { draft.hasPrefix("$") }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if cliMode {
                    Text("$")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accentColor)
                }
                TextField(cliMode ? (model.cliCwd.isEmpty ? "command…" : model.cliCwd) : "Ask…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit { submit() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        cliMode ? palette.accentColor.opacity(0.8)
                                : (inputFocused ? palette.accentColor.opacity(0.6) : .white.opacity(0.14)),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: (inputFocused || cliMode) ? palette.accentColor.opacity(0.22) : .clear, radius: 5)
            .animation(.easeInOut(duration: 0.22), value: inputFocused)
            .animation(.easeInOut(duration: 0.22), value: cliMode)

            Button {
                submit()
            } label: {
                Image(systemName: cliMode ? "chevron.right" : "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.interactive(), in: Circle())
            .help(cliMode ? "Run command" : "Send")
        }
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        if text.hasPrefix("$") {
            model.sendCli(text)
        } else {
            model.send(text)
        }
    }
}