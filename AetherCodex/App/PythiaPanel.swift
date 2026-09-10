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
    var expanded = true
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
    @Published var busy = false
    @Published var statusText: String?
    @Published var streamingText = ""
    @Published var streamingVisible = false
    @Published var cliCwd: String = ""
        /// One-click Riss macro offered when the daemon tears the thread — transient
        /// UI state, never persisted into the flow ledger.
        @Published var recoverCard: RecoverSuggestion?
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
                    reply = try await RubyBridge.shared.chatDetailed(messages: history)
                } else {
                    let answer = try await RubyBridge.shared.askCompanion(name: companion, question: history.last?["content"] ?? "")
                    reply = OracleReply(text: answer, reasoningContent: nil)
                }
                let finalText = reply.text ?? "The æther is silent."
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
        history = []  // companions are single-turn
        closeOpenToolGroup()
        streamingVisible = false
        streamingText = ""
        statusText = nil
        scheduleFlowSave()
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
                appendCliChip(args: stringify(data["args"]))
            } else {
                appendTool(name, args: stringify(data["args"]))
            }
        case "tool_completed":
            let name = (data["tool"] ?? data["name"]) as? String ?? ""
            if name == "run_command" { break }  // completed via command_completed
            completeTool(output: stringify(data["result"]))
        case "oracle_revelation", "oracle_conjuration_revelation":
            // Text closes any open tool run: a later tool call starts a new group.
            closeOpenToolGroup()
            streamingText = data["raw_content"] as? String ?? ""
            streamingVisible = true
        case "command_executing":
            // The agent's run_command tool — resolved into the open group's CLI
            // chip (the same unified shell block the user's `$` prompt produces).
            setCliChipCommand(data["command"] as? String ?? "")
        case "command_completed":
            if let cwd = data["cwd"] as? String, !cwd.isEmpty {
                cliCwd = cwd
            }
            completeCliChip(
                data["command"] as? String ?? "",
                output: data["content"] as? String ?? "",
                cwd: cliCwd,
                exitStatus: data["exit_status"] as? Int
            )
        case "system_error":
            statusText = "⚠️ \((data["message"] ?? data["error"]) as? String ?? "system error")"
        default:
            break
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
    private func appendTool(_ name: String, args: String = "") {
        appendChip(ToolChip(name: name, args: args, done: false))
    }

    /// The agent's run_command — a CLI chip inside the open group.
    private func appendCliChip(args: String = "") {
        appendChip(ToolChip(kind: .cli, name: "run_command", args: args, done: false, command: "", cwd: cliCwd))
    }

    private func appendChip(_ chip: ToolChip) {
        if let idx = openToolGroupIndex(),
           case .toolGroup(let group) = flow[idx] {
            var g = group
            g.tools.append(chip)
            g.expanded = true
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
    private func setCliChipCommand(_ cmd: String) {
        guard let idx = openToolGroupIndex(),
              case .toolGroup(let group) = flow[idx] else {
            appendCliChip()
            return
        }
        var g = group
        if let chipIdx = g.tools.lastIndex(where: { $0.kind == .cli && !$0.done }) {
            g.tools[chipIdx].command = cmd
            flow[idx] = .toolGroup(g)
            scheduleFlowSave()
        } else {
            appendCliChip()
        }
    }

    /// Fill the open CLI chip with command output, cwd and exit status.
    private func completeCliChip(_ cmd: String, output: String, cwd: String, exitStatus: Int?) {
        guard let idx = openToolGroupIndex(),
              case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        if let chipIdx = g.tools.lastIndex(where: { $0.kind == .cli && !$0.done }) {
            if !cmd.isEmpty { g.tools[chipIdx].command = cmd }
            g.tools[chipIdx].output = output
            g.tools[chipIdx].cwd = cwd
            g.tools[chipIdx].exitStatus = exitStatus
            g.tools[chipIdx].done = true
            flow[idx] = .toolGroup(g)
            scheduleFlowSave()
        }
    }

    /// Mark the newest unfinished *instrument* chip as completed. CLI chips are
    /// completed via command_completed, not here.
    private func completeTool(output: String) {
        guard let idx = flow.lastIndex(where: { if case .toolGroup = $0 { return true } else { return false } }) else { return }
        guard case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        if let chipIdx = g.tools.lastIndex(where: { $0.kind == .instrument && !$0.done }) {
            g.tools[chipIdx].done = true
            g.tools[chipIdx].output = output
        }
        flow[idx] = .toolGroup(g)
        scheduleFlowSave()
    }

    /// Coerce a Ruby-side value into a display string for tool args/output.
    private func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        return String(describing: value)
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
}

// MARK: - Pythia panel

struct PythiaPanel: View {
    @ObservedObject var model: PythiaChatModel
    @ObservedObject private var aetherContext = AetherContext.shared

    var body: some View {
        MessageList(model: model)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .safeAreaBar(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            CompanionPicker(model: model)
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
        .foregroundStyle(.white)
        .help("Show Æther Debug")
    }
}

// MARK: - Context pill

/// The active project's identity — a quiet glyph + name that lets the window
/// advertise *which* æther it is currently breathing. "ICH bin der ÆTHER."
private struct ContextPill: View {
    @ObservedObject var context: AetherContext

    var body: some View {
        HStack(spacing: 5) {
            Text("◈")
                .font(.system(size: 10))
                .foregroundStyle(context.configPath != nil ? Color.accentColor : Color.secondary)
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
                    let active = model.companionID == companion.id
                    Button {
                        model.selectCompanion(companion.id)
                    } label: {
                        Text(companion.glyph)
                            .font(.system(size: 13))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(active ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: Circle())
                    .overlay(
                        Circle().strokeBorder(
                            active ? Color.accentColor.opacity(0.7) : .white.opacity(0.10),
                            lineWidth: 0.75
                        )
                    )
                    .scaleEffect(active ? 1.06 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.78), value: active)
                    .help(companion.label)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - CLI block

/// The unified shell block woven into the flow — produced both by the user's `$`
/// prompt and by the agent's `run_command` tool. Two hands, one interface.
private struct CliBlock: View {
    let entry: CliEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(highlightCode(entry.command, language: "shell"))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if entry.done {
                    Image(systemName: entry.exitStatus == 0 ? "checkmark.circle" : "xmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(entry.exitStatus == 0 ? Color.secondary : Color.red.opacity(0.8))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if !entry.output.isEmpty {
                Text(highlightCode(entry.output, language: "shell"))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// Reports the bottom sentinel's vertical position in the scroll viewport so the
/// message list can tell whether the reader is parked at the live edge or has
/// deliberately scrolled up into older flow (in which case autoscroll must yield).
private struct ScrollSentinelKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Reports the scroll viewport's height so the sentinel offset can be interpreted
/// as "how far below the fold the live edge sits".
private struct ScrollViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MessageList: View {
    @ObservedObject var model: PythiaChatModel
    @State private var breathing = false
    /// Sentinel minY within the viewport coordinate space.
    @State private var sentinelMinY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// True when the live edge is (roughly) in view — autoscroll may follow.
    @State private var isNearBottom = true

    /// How far below the viewport fold the live edge may drift before we stop
    /// yanking the reader down and instead surface the "jump to bottom" arrow.
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
                            ToolGroupView(model: model, groupID: group.id)
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
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ScrollSentinelKey.self,
                                    value: geo.frame(in: .named("pythiaScroll")).minY
                                )
                            }
                        )
                }
                .padding(10)
            }
            .coordinateSpace(name: "pythiaScroll")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollViewportKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ScrollSentinelKey.self) { minY in
                sentinelMinY = minY
                updateProximity()
            }
            .onPreferenceChange(ScrollViewportKey.self) { h in
                viewportHeight = h
                updateProximity()
            }
            .onChange(of: model.scrollAnchor) { _, _ in
                // A fresh user/CLI turn always wins the reader's attention.
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                isNearBottom = true
            }
            .onChange(of: model.flow) { _, _ in
                followLiveEdge(proxy)
            }
            .onChange(of: model.streamingText) { _, _ in
                followLiveEdge(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom {
                    jumpToBottomButton(proxy)
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isNearBottom)
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
    /// parked near the bottom. Once they scroll up, the thread belongs to them.
    private func followLiveEdge(_ proxy: ScrollViewProxy) {
        guard isNearBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// Re-derive "near bottom" from the sentinel's position vs. the viewport
    /// height. Sentinel sits at the live edge; when scrolled up it drifts past
    /// the fold and flips this flag off.
    private func updateProximity() {
        let near = sentinelMinY <= viewportHeight + proximityThreshold
        if isNearBottom != near {
            isNearBottom = near
        }
    }

    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            isNearBottom = true
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
    let groupID: UUID

    private var group: ToolGroup? {
        for entry in model.flow {
            if case .toolGroup(let g) = entry, g.id == groupID { return g }
        }
        return nil
    }

    var body: some View {
        if let group {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.toggleToolGroup(groupID)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(group.expanded ? 90 : 0))
                        Text(group.tools.count == 1 ? "1 Instrument" : "\(group.tools.count) Instrumente")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if group.expanded {
                    ForEach(group.tools) { chip in
                        ToolChipRow(chip: chip)
                    }
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: group.expanded)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
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
    let chip: ToolChip

    var body: some View {
        if chip.kind == .cli {
            CliChipView(chip: chip)
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
            HStack(spacing: 5) {
                Text(sem.glyph)
                    .font(.system(size: 11))
                Text(sem.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                Text(chip.name)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if chip.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(sem.tint)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if !chip.args.isEmpty {
                Text(chip.args)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.tail)
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

/// The agent's run_command rendered as the unified shell block — but *inside*
/// the instrumenta group, so consecutive tool calls stay one collapsible unit.
private struct CliChipView: View {
    let chip: ToolChip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(highlightCode(chip.command.isEmpty ? "run_command" : chip.command, language: "shell"))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if chip.done {
                    Image(systemName: chip.exitStatus == 0 ? "checkmark.circle" : "xmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(chip.exitStatus == 0 ? Color.secondary : Color.red.opacity(0.8))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if !chip.output.isEmpty {
                Text(highlightCode(chip.output, language: "shell"))
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.mint.opacity(0.25), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Riss recovery card

/// The one-click re-weave macro: when the daemon's worker tears the thread,
/// the companion becomes the next chapter's beginning instead of a dead error.
private struct RecoverCardView: View {
    let card: RecoverSuggestion
    @ObservedObject var model: PythiaChatModel

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
                    .background(Color.accentColor, in: Capsule())
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
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75)
        )
        .shadow(color: Color.accentColor.opacity(0.18), radius: 6, y: 2)
    }
}

// MARK: - Companion speech bubbles

/// Omnipresent companion voices: the reply's extracted suggestions become
/// one-click macros — the pantheon speaks through the UI, not JSON chips.
private struct CompanionBubbleBar: View {
    @ObservedObject var model: PythiaChatModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.companionBubbles) { bubble in
                    Button {
                        model.actionCompanionBubble(bubble)
                    } label: {
                        HStack(spacing: 5) {
                            Text(bubble.glyph)
                                .font(.system(size: 11))
                            if !bubble.name.isEmpty {
                                Text(bubble.name)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(bubble.prompt)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(bubble.prompt)
                }
            }
        }
    }
}

// MARK: - Input bar

private struct InputBar: View {
    @ObservedObject var model: PythiaChatModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    /// `$` as the first character opens the polymorphic Pythia CLI: the same
    /// shell the agent's `run_command` tool inhabits. One interface, two hands.
    private var cliMode: Bool { draft.hasPrefix("$") }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if cliMode {
                    Text("$")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
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
                        cliMode ? Color.accentColor.opacity(0.8)
                                : (inputFocused ? Color.accentColor.opacity(0.6) : .white.opacity(0.14)),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: (inputFocused || cliMode) ? Color.accentColor.opacity(0.22) : .clear, radius: 5)
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