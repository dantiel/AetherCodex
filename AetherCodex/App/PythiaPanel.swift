import SwiftUI
import AppKit

// MARK: - Models

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let role: String  // "user" | "assistant"
    let text: String
    let glyph: String
    /// The model's reasoning_content (DeepSeek thinking mode) — rendered as a
    /// collapsible "Gedanke" block above the answer, not hidden from view.
    var reasoning: String? = nil
    /// Non-empty when this voice is a companion speaking through Pythia's turn.
    /// nil means Pythia's own voice — the stream of consciousness flowing into
    /// the base as plain text (no bubble, no glyph chrome). Optional so old
    /// persisted snapshots (before the speech-bubble split) decode cleanly.
    var speakerName: String? = nil
}

struct Companion: Identifiable {
    let id: String
    let glyph: String
    let label: String
    /// Full hermetic name (e.g. "Codex Corax"), shown in the companion menu.
    var title: String = ""
    /// The domain a companion answers for — its trigger/ability, one line.
    var trigger: String = ""
    /// Execution grant tier: spy (read-only) · scribe (writes) · executor (writes + confirms).
    var grant: String = ""
    /// Reach: "seer" companions carry the æther (cross-context tools).
    var reach: String = ""
    /// Curated domain tools the companion contributes when active.
    var tools: [String] = []

    /// Full name when known, short label otherwise.
    var displayName: String { title.isEmpty ? label : title }
}

/// A transient companion voice offered as a one-click macro — not part of the
/// persisted flow (no Codable churn). Clicking re-sends the prompt as a turn.
struct CompanionBubble: Identifiable, Equatable {
    let id = UUID()
    let glyph: String
    let name: String
    let prompt: String
}


/// A pending user consultation raised by the agent's `ask_user` instrument —
/// the running turn pauses until the user answers (confirm / select / prompt).
struct AskUserPrompt: Identifiable, Equatable {
    let id = UUID()
    let uuid: String
    let type: String
    let message: String
    let options: [String]
}

/// Mirrors the companion roster of Pythia/chamber.html exactly.
/// Local fallback until the daemon's first `ready` frame arrives — the same
/// pantheon the wire roster carries, plus Pythia. Divergence here would show a
/// partial pantheon for the instant before the bridge connects (correspondence,
/// not duplication).
let pythiaCompanions: [Companion] = [
    Companion(id: "pythia", glyph: "🐍", label: "Pythia", title: "Pythia",
              trigger: "Standard-Orakel — das Zuhause aller Stimmen"),
    Companion(id: "owl", glyph: "🦉", label: "Owl", title: "Eule der Athene",
              trigger: "Überblick / Architektur / \"wie hängt das zusammen\"",
              grant: "scribe", reach: "seer",
              tools: ["file_overview", "read_file", "recall_notes"]),
    Companion(id: "kitsune", glyph: "🦊", label: "Kitsune", title: "Inari-no-Kitsune",
              trigger: "Alternativen / \"gibt es einen anderen Weg\"",
              grant: "scribe",
              tools: ["file_overview", "read_file", "recall_notes"]),
    Companion(id: "phoenix", glyph: "🔥", label: "Phoenix", title: "Bennu Aeternus",
              trigger: "Fehler / Test-Failure / Rückschlag",
              grant: "scribe",
              tools: ["read_file", "run_command", "remember"]),
    Companion(id: "ouroboros", glyph: "🐍", label: "Ouroboros", title: "Jörmungandr",
              trigger: "Technische Schuld / Wiederholung / Zyklen",
              grant: "scribe",
              tools: ["file_overview", "read_file", "recall_notes"]),
    Companion(id: "bastet", glyph: "🐈", label: "Bastet", title: "Bastet-Mafdet",
              trigger: "Code-Review / Smell / Eleganz",
              grant: "executor",
              tools: ["run_command", "read_file", "file_overview"]),
    Companion(id: "fenrir", glyph: "🐺", label: "Fenrir", title: "Fenrisúlfr",
              trigger: "Vereinfachen / \"zu komplex\" / \"kürzen\" / \"rauswerfen\"",
              grant: "executor",
              tools: ["file_overview", "read_file", "recall_notes"]),
    Companion(id: "undine", glyph: "🌊", label: "Undine", title: "Undine von Paracelsus",
              trigger: "Datenfluss / Engpass / Performance",
              grant: "spy",
              tools: ["file_overview", "read_file", "recall_notes"]),
    Companion(id: "schwan", glyph: "🦢", label: "Schwan", title: "Amphitryon",
              trigger: "Verschönern / lesbarer / Ästhetik",
              grant: "scribe",
              tools: ["read_file", "file_overview"]),
    Companion(id: "drache", glyph: "🐉", label: "Drache", title: "Shenlong",
              trigger: "Konsistenz / Integrität / \"läuft alles\"",
              grant: "spy", reach: "seer",
              tools: ["run_command", "recall_notes", "remember"]),
    Companion(id: "corax", glyph: "⬛", label: "Corax", title: "Codex Corax",
              trigger: "Totes finden / Verwaistes / \"wird das noch gebraucht\"",
              grant: "spy", reach: "seer",
              tools: ["file_overview", "read_file", "recall_notes", "run_command"]),
    Companion(id: "jindujun", glyph: "☁️", label: "Jindujun", title: "Kintōun — die Überschallwolke",
              trigger: "Cross-Context / ÆtherLink / \"reise zu\" / \"übernimm dort\"",
              grant: "scribe", reach: "seer",
              tools: ["metempsychosis", "create_task", "execute_task", "evaluate_task", "recall_notes", "read_file"]),
    Companion(id: "solomon", glyph: "👑", label: "Solomon", title: "Salomo Rex",
              trigger: "Planung / Projekt / \"was zuerst\" / Orchestrierung / Koordination",
              grant: "executor", reach: "seer",
              tools: ["list_tasks", "create_task", "evaluate_task", "update_task", "recall_notes", "read_file", "file_overview"]),
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

/// Coerce a Ruby-side value into a display string for tool args/output.
/// Structured values become readable JSON (not Swift's `["key": …]` dump),
/// so Mnemosyne & co. can be rendered as *meaning*, not a debug fragment.
/// Shared by Pythia's and Salomo's stream handlers.
func instrumentaStringify(_ value: Any?) -> String {
    guard let value else { return "" }
    if let s = value as? String { return s }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        return json
    }
    return String(describing: value)
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
        if !args.isEmpty {
            // Begleiter-Gesten sprechen selbst — kein generischer Label-Dump.
            if let line = CompanionTool.minifiedLine(name: name, args: args) { return line }
            return "\(sem.glyph) \(sem.label) \(name)"
        }
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

/// Aegis — the oracle's own context-shift instrument. It is *not* a working-tool
/// card buried in a group: it marks a course change in the model's thinking, so
/// it surfaces as a full-width system veil with the prominence of an AI message.
struct AegisRevelation: Identifiable, Equatable, Codable {
    var id = UUID()
    /// Rich header line — the horologium message stripped to plain text.
    var header: String = "Aegis"
    /// Markdown body (summary + thinking/temperature meta). Legacy/fallback for
    /// persisted entries from before the summary/notes split.
    var body: String = ""
    /// The new orientation summary — rendered prominently, not as a chip.
    var summary: String = ""
    /// Recalled notes, collapsed like memories beneath the summary.
    var notes: [AegisNote] = []
    var tags: [String] = []
    var thinking: String?
    var temperature: Double?
}

extension AegisRevelation {
    /// Build a revelation from an `aegis_unveiled` status payload. Shared by
    /// Pythia's and Salomo's stream handlers so both render the same veil.
    static func from(_ data: [String: Any]) -> AegisRevelation {
        var revelation = AegisRevelation()
        if let msg = data["message"] as? String {
            revelation.header = InstrumentaStatus.plainText(fromHTML: msg)
        }
        // The daemon ships both the rendered HTML and the raw markdown — render
        // the markdown so headings, bold and code blocks keep their shape.
        if let raw = data["raw"] as? String, !raw.isEmpty {
            revelation.body = raw
        } else if let content = data["content"] as? String {
            revelation.body = InstrumentaStatus.plainText(fromHTML: content)
        }
        if let summary = data["summary"] as? String, !summary.isEmpty {
            revelation.summary = summary
        }
        if let notesData = data["notes"] as? [[String: Any]] {
            revelation.notes = notesData.map(AegisNote.init(from:))
        }
        if let tags = data["tags"] as? [String] {
            revelation.tags = tags
        } else if let tagString = data["tags"] as? String, !tagString.isEmpty {
            revelation.tags = tagString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        revelation.thinking = data["thinking"] as? String
        revelation.temperature = (data["temperature"] as? NSNumber)?.doubleValue
        return revelation
    }
}

/// One recalled note inside an Aegis veil — the same shape Mnemosyne returns,
/// parsed from the structured `notes` payload so it renders as a memory card
/// instead of flattened markdown.
struct AegisNote: Identifiable, Equatable, Codable {
    var id: Int
    var content: String
    var tags: [String]
    var links: [String]
    var createdAt: String
    var score: Double

    init(id: Int = 0, content: String = "", tags: [String] = [],
         links: [String] = [], createdAt: String = "", score: Double = 0) {
        self.id = id
        self.content = content
        self.tags = tags
        self.links = links
        self.createdAt = createdAt
        self.score = score
    }

    init(from dict: [String: Any]) {
        id = (dict["id"] as? Int) ?? 0
        content = (dict["content"] as? String) ?? ""
        tags = Self.splitList(dict["tags"])
        links = Self.splitList(dict["links"])
        createdAt = (dict["created_at"] as? String) ?? (dict["updated_at"] as? String) ?? ""
        if let s = dict["score"] as? Double { score = s }
        else if let i = dict["score"] as? Int { score = Double(i) }
        else { score = 0 }
    }

    private static func splitList(_ value: Any?) -> [String] {
        if let arr = value as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let s = value as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}

/// A system-level notice woven into the flow — the daemon's own voice (error,
/// drift warning, mid-process info). It is *not* a working-tool chip nor an AI
/// message: it is the æther speaking, so it lands as a quiet full-width veil
/// that persists in the timeline instead of a transient footer status that
/// vanishes with the next live update.
struct SystemMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let text: String
    let level: String  // "info" | "warn" | "error"
    let kind: String   // "info" | "peer_drift" | "system_error"
}

/// One node in the unified flow timeline. Messages, tool groups and CLI
/// blocks share a single ordered list so each lands exactly where it happened
/// — no more "all CLI output after all messages".
enum FlowEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case toolGroup(ToolGroup)
    case cli(CliEntry)
    case aegis(AegisRevelation)
    case system(SystemMessage)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .toolGroup(let g): return g.id
        case .cli(let c): return c.id
        case .aegis(let a): return a.id
        case .system(let s): return s.id
        }
    }

    /// A short, git-commit-style hash derived from the stable node id. Rendered
    /// whisper-quiet in the timeline gutter so every prompt, instrumenta call and
    /// oracle output reads as a commit — an identity, not a nameless bubble.
    var shortHash: String { String(id.uuidString.prefix(6)) }
}

// Codable for a tagged union — Swift does not synthesize Codable for enums with
// associated values, so each case is boxed as { "type": …, "value": … }.
extension FlowEntry: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum CaseType: String, Codable { case message, toolGroup, cli, aegis, system }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(CaseType.self, forKey: .type) {
        case .message:    self = .message(try c.decode(ChatMessage.self, forKey: .value))
        case .toolGroup:  self = .toolGroup(try c.decode(ToolGroup.self, forKey: .value))
        case .cli:        self = .cli(try c.decode(CliEntry.self, forKey: .value))
        case .aegis:      self = .aegis(try c.decode(AegisRevelation.self, forKey: .value))
        case .system:     self = .system(try c.decode(SystemMessage.self, forKey: .value))
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
        case .aegis(let a):
            try c.encode(CaseType.aegis, forKey: .type)
            try c.encode(a, forKey: .value)
        case .system(let s):
            try c.encode(CaseType.system, forKey: .type)
            try c.encode(s, forKey: .value)
        }
    }
}

// MARK: - Live decay (compaction)

/// Mirror of `Mnemosyne.compaction_level` — the same recency-decay law that
/// compacts token history now compacts the visible timeline. Presence is an
/// exponential function of distance from the live edge:
///   presence = base · e^(−distance / rate)
/// mapped onto four interface tiers. Distance is measured in *flow entries*
/// (finer than the memory's *turns*), so the interface uses the gentler rate
/// 3.0 while obeying the identical arithmetic — correspondence, not duplication.
/// The live edge is always `.expanded`; deep history collapses to a one-line
/// `.micro` whisper.
enum CompactionLevel: Int, Comparable, CaseIterable {
    case expanded = 0   // full presence — the present
    case medium = 1     // body only, no reasoning chrome
    case compact = 2    // clamped plain preview
    case micro = 3      // one line, horizontal ellipsis

    static let base: Double = 3.0
    static let rate: Double = 3.0          // flow-entry half-life scale
    static let thresholds: [Double] = [1.8, 0.6, 0.18]

    static func level(distanceFromEnd: Int) -> CompactionLevel {
        let presence = base * exp(-max(Double(distanceFromEnd), 0) / rate)
        if presence >= thresholds[0] { return .expanded }
        if presence >= thresholds[1] { return .medium }
        if presence >= thresholds[2] { return .compact }
        return .micro
    }

    static func < (lhs: CompactionLevel, rhs: CompactionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension ChatMessage {
    /// A single-line, markdown-stripped preview for the compact/micro tiers — the
    /// message's meaning condensed to a whisper, like token history collapsing
    /// toward the live edge.
    var oneLinePreview: String {
        var s = text
        // Fenced code blocks collapse to a single token so a far-past answer
        // does not leak its whole listing into the whisper line.
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ⟨code⟩ ",
                                    options: .regularExpression)
        // Strip inline formatting glyphs.
        for token in ["`", "**", "__", "~~", "***"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        // Headings, blockquotes, list markers lose their glyphs.
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "",
                                    options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^>\\s?", with: "",
                                    options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "",
                                    options: .regularExpression)
        // Collapse all whitespace into single spaces.
        s = s.replacingOccurrences(of: "\\s+", with: " ",
                                    options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Transient UI state: user messages folded into the flow while a turn was
    /// already running (queued interjections). Rendered with a quiet "wartet"
    /// marker until the next turn picks them up — the only visual trace of the
    /// git-flow rebase. Never persisted.
    @Published var queuedMessageIDs: Set<UUID> = []
    /// Transient UI state: messages that were queued behind a running turn and
    /// have since merged back into the linear flow. Kept separate from
    /// `queuedMessageIDs` so the confluence stays legible *after* the rebase —
    /// a quiet "⇥ rebased" trace instead of an invisible merge. Never persisted.
    @Published var rebasedMessageIDs: Set<UUID> = []
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
        /// The course is held: conjoined suggestions accumulate in the Ægis
        /// instead of opening a turn. A typed prompt always runs — the hold
        /// governs the pantheon, never the user's own hand.
        @Published var paused = false
        /// A *running* turn is held (⏸) at its next step boundary. The daemon
        /// keeps the chapter alive — thread, messages, stream — so ▶ continues it
        /// and a prompt typed during the hold is woven into it before its next
        /// step. `paused` is the user's intent, `heldTurn` the turn's fact.
        @Published var heldTurn = false
        /// A companion suggestion loaded into the input bar as an editable quote
        /// (transient — cleared by InputBar once it adopts the draft).
        @Published var pendingPrompt: String? = nil
        /// The input bar's in-progress draft. Lives on the model (not `@State` in
        /// `InputBar`) so an un-sent prompt survives the inspector being torn down
        /// and rebuilt — closing/reopening Pythia must not eat the user's words.
        @Published var draft: String = ""
        /// A pending user consultation raised by the agent's `ask_user` instrument.
        /// The running turn is paused until `respondToAskUser` answers it.
        @Published var activeAskUser: AskUserPrompt? = nil
        /// Monotonic scroll anchor: bumped whenever a fresh user/CLI turn lands so
        /// the message list always jumps to the newest chapter — even if the reader
        /// had scrolled up into older flow.
        @Published var scrollAnchor = 0
        /// Paged loading: the flow ledger grows unbounded, so only the newest
        /// `initialPageSize` entries are restored at startup; older chapters are
        /// pulled in lazily when the reader scrolls to the top.
        @Published var hasMoreOlder = false
        @Published var isLoadingOlder = false
        private var earliestLoadedSeq: Int64 = 0
        // Small first page: restoring a long flow ledger should be instant. Older
        // chapters are pulled lazily only when the reader scrolls to the top.
        private let initialPageSize = 40

    private var history: [[String: String]] = []
    /// Per-voice conversation history, keyed by companion id ("pythia" included).
    /// Each companion keeps its own multi-turn memory so a direct conversation —
    /// including repetitive tasks like build/deploy — persists across turns.
    private var companionHistories: [String: [[String: String]]] = [:]
    private var hasRestoredSession = false
    private var saveWorkItem: DispatchWorkItem?
    private var flowObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var recoverObserver: NSObjectProtocol?
    private var isPersisting = false
    private var boundContextRoot: String?
    /// Suggestion intents conjoined while the course was held — they fly on ▶.
    private var pendingCourseIntents: [String] = []
    /// Turn epoch. Bumped by ⏹ so a torn chapter's late reply is discarded
    /// instead of landing in a flow it no longer belongs to.
    private var turnGeneration = 0
    /// Watch for a freshly drafted Ægis course, woven into the flow as a veil.
    private var courseObserver: NSObjectProtocol?

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
        // A new course is a boundary in the thinking, not a chip: the Ægis
        // drafts it, the conversation records the shift.
        courseObserver = NotificationCenter.default.addObserver(
            forName: AegisWidgetModel.coursePlanDidLand, object: nil, queue: .main
        ) { [weak self] note in
            guard let plan = note.userInfo?["plan"] as? String, !plan.isEmpty else { return }
            MainActor.assumeIsolated { self?.coursePlanDidLand(plan) }
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
        if let snapshot = PythiaFlowStore.shared.load(forContext: boundContextRoot, limit: initialPageSize) {
            apply(snapshot: snapshot)
            statusText = Self.resumeStatus(snapshot)
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
        if let snapshot = PythiaFlowStore.shared.load(forContext: newRoot, limit: initialPageSize) {
            apply(snapshot: snapshot)
            statusText = Self.resumeStatus(snapshot)
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
            statusText = "🔗 Merged flow from \((otherContext as NSString).lastPathComponent)"
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
        // Re-read the paged window from the ledger rather than applying the
        // sender's in-memory snapshot — the sibling may hold only its own page.
        if let snapshot = PythiaFlowStore.shared.load(forContext: boundContextRoot, limit: initialPageSize) {
            apply(snapshot: snapshot)
        }
    }

    private func apply(snapshot: PythiaFlowStore.Snapshot) {
        flow = snapshot.flow
        history = snapshot.history
        if !snapshot.cwd.isEmpty {
            cliCwd = snapshot.cwd
        }
        earliestLoadedSeq = snapshot.earliestSeq
        hasMoreOlder = snapshot.hasMoreOlder
    }

    /// Pull one older page into the front of the timeline, pinning the viewport
    /// to the entry that was previously first so the reader's position holds.
    func loadOlderPage(_ proxy: ScrollViewProxy) {
        guard hasMoreOlder, !isLoadingOlder, let root = boundContextRoot else { return }
        isLoadingOlder = true
        let anchorID = flow.first?.id
        let beforeSeq = earliestLoadedSeq
        let limit = initialPageSize
        Task { [weak self] in
            guard let self else { return }
            let page = await Task.detached(priority: .userInitiated) {
                PythiaFlowStore.shared.loadOlder(forContext: root, beforeSeq: beforeSeq, limit: limit)
            }.value
            guard let page, !page.flow.isEmpty else {
                self.isLoadingOlder = false
                return
            }
            self.flow = page.flow + self.flow
            self.earliestLoadedSeq = page.earliestSeq
            self.hasMoreOlder = page.hasMoreOlder
            self.isLoadingOlder = false
            if let anchorID {
                // One runloop hop so SwiftUI commits the prepended rows before
                // re-anchoring the reader to their previous top entry.
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        }
    }

    private static func resumeStatus(_ snapshot: PythiaFlowStore.Snapshot) -> String {
        let n = snapshot.flow.count
        let word = n == 1 ? "entry" : "entries"
        if snapshot.hasMoreOlder {
            return "📜 Resumed \(n) of \(snapshot.totalCount) flow \(word) — scroll up for earlier"
        }
        return "📜 Resumed \(n) flow \(word)"
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

    /// Send a turn. `keepingSuggestions` preserves the companion bubbles — a
    /// course turn must not sweep the other suggestions away, so the pantheon
    /// stays one click from joining.
    func send(_ text: String, keepingSuggestions: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Gist Bus: "@all …" / "@schwan …" broadcasts a message into every
        // relevant flow's conduit instead of starting a turn. The running turn
        // is never aborted; the broadcast lands at each flow's next conduit build.
        if let (target, content) = Self.parseBroadcast(trimmed) {
            broadcast(content: content, target: target)
            return
        }
        recoverCard = nil          // a fresh chapter closes the torn-thread offer
        if !keepingSuggestions {
            companionBubbles = []  // the new turn speaks; old voices step back
        }
        trimHistory()  // count is even here: ends on assistant
        let message = ChatMessage(role: "user", text: trimmed, glyph: currentGlyph)
        appendMessage(message)
        history.append(["role": "user", "content": trimmed])
        scrollAnchor += 1  // a new chapter always snaps the reader to the newest line
        if !busy {
            // A genuinely fresh chapter: the previous episode's rebase trace
            // dissolves so only the current confluence stays legible.
            rebasedMessageIDs.removeAll()
        }
        // ⏸ Held chapter: the word is *woven into* the running turn instead of
        // queueing behind it — the agent sees it before it takes its next step.
        // The daemon appends it to the live messages at the boundary; the flow
        // marks it as rebased (an interjection merged into the running branch,
        // not parked behind it).
        if busy && (heldTurn || paused) {
            heldTurn = true
            paused = false
            rebasedMessageIDs.insert(message.id)
            Task { [weak self] in
                let woven = await RubyBridge.shared.weaveTurn(text: trimmed)
                await MainActor.run {
                    guard let self else { return }
                    self.heldTurn = false
                    self.paused = false
                    self.statusText = nil
                    // The chapter had already closed — the word becomes its own.
                    if !woven { self.beginTurn() }
                }
            }
            return
        }
        // Interjection while busy: the running turn is NOT aborted. The message
        // is folded into the flow and history; beginTurn() re-runs after the
        // current turn completes (git-flow merge: linear, rebased interjection).
        // It carries a transient "wartet" marker until that turn begins.
        guard !busy else {
            queuedMessageIDs.insert(message.id)
            return
        }
        beginTurn()
    }

    /// Send a Gist-Bus broadcast: a user message woven into the conduit of every
    /// relevant flow (target nil = all) or one companion (target = its id). It
    /// shows as a quiet system veil in the local flow and does not start a turn.
    func broadcast(content: String, target: String?) {
        let label = target.map { "→ \($0)" } ?? "→ alle"
        appendSystemMessage(kind: "broadcast",
                            data: ["message": "📡 Broadcast \(label): \(content)"],
                            level: "info")
        scrollAnchor += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                if !RubyBridge.shared.isRunning { try await RubyBridge.shared.start() }
                _ = try await RubyBridge.shared.gistBroadcast(content: content, target: target)
            } catch {
                await MainActor.run {
                    self.appendSystemMessage(kind: "system_error",
                                             data: ["message": "⚠️ Broadcast failed: \(error.localizedDescription)"],
                                             level: "error")
                }
            }
        }
    }

    /// Parse the broadcast prefix. "@all"/"@alle"/"@pythia" → every flow;
    /// "@<companion-id>" → that companion only. Anything unrecognized returns
    /// nil so the text falls through to a normal turn (a plain "@" mention).
    private static func parseBroadcast(_ text: String) -> (target: String?, content: String)? {
        guard text.hasPrefix("@") else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let token = String(first.dropFirst())
        guard token == "all" || token == "alle" || pythiaCompanions.contains(where: { $0.id == token }) else {
            return nil
        }
        let content = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard !content.isEmpty else { return nil }
        let target: String? = (token == "all" || token == "alle" || token == "pythia") ? nil : token
        return (target, content)
    }

    private func beginTurn() {
        busy = true
        turnGeneration += 1
        let generation = turnGeneration
        // Queued interjections are now being answered — they rebase onto the
        // linear flow. Their "wartet" marker dissolves into a lasting "rebased"
        // trace so the confluence stays legible even after the merge.
        rebasedMessageIDs.formUnion(queuedMessageIDs)
        queuedMessageIDs = []
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
                    // Direct companion speech routes through the oracle channel with
                    // the companion veiled — full toolset + persistent history, so the
                    // companion can actually act (build, deploy, …) across turns.
                    reply = try await RubyBridge.shared.chatCompanion(name: companion, messages: history)
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
                    // ⏹ tore this chapter — discard the reply it no longer owns.
                    guard generation == self.turnGeneration else { return }
                    self.streamingVisible = false
                    self.statusText = nil
                    // ⏸/⏹: the turn stopped at its boundary instead of answering
                    // (a context switch unwound it) — there is no answer to show.
                    guard !reply.held else {
                        self.busy = false
                        self.heldTurn = false
                        self.paused = false
                        self.collapseCompletedToolGroups()
                        return
                    }
                    self.appendMessage(ChatMessage(role: "assistant", text: finalText, glyph: glyph, reasoning: reply.reasoningContent))
                    self.history.append(assistantEntry)
                    // The active pantheon answers through Pythia's turn: each
                    // `_say`/`_ask` voice lands as its own message with its glyph.
                    for say in reply.companionSays {
                        let displayName = pythiaCompanions.first { $0.id == say.name }?.displayName ?? say.name
                        self.appendMessage(ChatMessage(role: "assistant", text: say.message,
                                                       glyph: say.glyph, speakerName: displayName))
                    }
                    self.companionBubbles = bubbles
                    self.trimHistory()  // count even again after assistant
                    self.collapseCompletedToolGroups()
                    self.busy = false
                }
                // Merge: interjections queued while this turn ran continue the flow.
                // This turn appended exactly one assistant entry, so anything
                // beyond +1 is a fresh user interjection waiting to be answered.
                guard generation == self.turnGeneration else { return }
                if self.history.count > sentHistoryCount + 1 {
                    self.beginTurn()
                }
            } catch {
                await MainActor.run {
                    guard generation == self.turnGeneration else { return }
                    self.streamingVisible = false
                    self.statusText = nil
                    self.busy = false
                    self.appendMessage(ChatMessage(role: "assistant",
                                                    text: "⚠️ \(error.localizedDescription)",
                                                    glyph: glyph))
                    self.collapseCompletedToolGroups()
                }
                guard generation == self.turnGeneration else { return }
                if self.history.count > sentHistoryCount {
                    self.beginTurn()
                }
            }
        }
    }

    /// Whether an assistant message is a transient failure a plain "Continue"
    /// can retry (server overload, rate limit, too busy, …). Deterministic — it
    /// never mistakes a real oracle answer for a failure. The daemon may prefix
    /// the raw provider error with its own glyph (⚠️/❌), so we match on the
    /// provider's own words, not the glyph.
    static func isRetryableError(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("server overloaded")
            || t.contains("overloaded due to")
            || t.contains("service is too busy")
            || t.contains("api error")
            || t.contains("rate limit")
            || t.contains("please retry your request")
            || t.contains("temporarily switch to alternative")
    }

    /// Re-issue the last turn after a transient failure. The user's prompt is
    /// already woven into `history`, so this only calls `beginTurn()` again — no
    /// duplicate user message. The trailing error veil is retracted first so the
    /// timeline doesn't accumulate a dead end.
    func retryLastTurn() {
        guard !busy else { return }
        if case .message(let last) = flow.last,
           last.role == "assistant",
           Self.isRetryableError(last.text) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                _ = flow.removeLast()
            }
            scheduleFlowSave()
        }
        beginTurn()
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

    /// Bound conversation history to the last 8 entries (4 exchanges). Trim
    /// points are chosen so `history.count` is always even (user/assistant pairs
    /// stay intact). Drastically reduced to keep the model's context quota lean.
    private func trimHistory() {
        let maxEntries = 8
        if history.count > maxEntries {
            history.removeFirst(history.count - maxEntries)
        }
    }

    func selectCompanion(_ id: String) {
        // Stash the current voice's history so each companion (and Pythia) keeps
        // its own multi-turn memory — companions become persistent agents that can
        // carry out repetitive tasks (build, deploy) across turns.
        companionHistories[companionID] = history
        companionID = id
        // Speaking to a companion directly veils it into the æther — activation
        // is implied by direct speech. Default Pythia stays the home voice.
        if id != "pythia" && !activeCompanions.contains(id) {
            activeCompanions.insert(id)
            persistActiveCompanions()
        }
        history = companionHistories[id] ?? []
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

    // MARK: The course — the Ægis assembles, Pythia conducts

    /// Resolve the companion behind a suggestion bubble by glyph first, then by
    /// id / display name / label. Robust across the wire roster's naming.
    private func companion(for bubble: CompanionBubble) -> Companion? {
        pythiaCompanions.first { $0.glyph == bubble.glyph }
            ?? pythiaCompanions.first { $0.id == bubble.name || $0.displayName == bubble.name || $0.label == bubble.name }
    }

    /// Is this suggestion already holding a seat in the course? Membership is
    /// derived from the Ægis itself — a bubble never carries its own.
    func isConjoined(_ bubble: CompanionBubble) -> Bool {
        let id = companion(for: bubble)?.id ?? bubble.name
        return AegisWidgetModel.shared.conjunction.contains { $0.companionID == id }
    }

    /// Conjoin a suggestion into the Ægis — and start working on it at once.
    /// The team travels inside the orientation (facet tags + summary), which the
    /// hidden Coniunctio weaves into the turn's context; the prompt carries only
    /// the new intent. The bubble stays in the flow, so the remaining
    /// suggestions stay one click away and simply extend the course.
    func conjoinBubble(_ bubble: CompanionBubble) {
        let companion = companion(for: bubble)
        let member = AegisConjunctionMember(
            companionID: companion?.id ?? bubble.name,
            glyph: bubble.glyph,
            name: companion?.displayName ?? bubble.name,
            intent: bubble.prompt
        )
        guard AegisWidgetModel.shared.conjoin(member) else { return }
        startCourseTurn(intent: bubble.prompt)
    }

    /// Conjoin a bare facet — a companion summoned with no pending suggestion.
    /// Nothing to work on yet, so the course grows without a turn.
    func conjoinCompanion(_ companion: Companion) {
        AegisWidgetModel.shared.conjoin(AegisConjunctionMember(
            companionID: companion.id,
            glyph: companion.glyph,
            name: companion.displayName,
            intent: nil
        ))
    }

    /// "An Prompt anhängen" — quote the suggestion into the input bar without
    /// sweeping the other bubbles, so several companions can be quoted together
    /// and answered as a team after the user adds their own words.
    func quoteBubble(_ bubble: CompanionBubble) {
        let quoted = "\(bubble.glyph) \(bubble.prompt)"
        if let existing = pendingPrompt, !existing.isEmpty {
            pendingPrompt = existing + "\n\n" + quoted
        } else {
            pendingPrompt = quoted
        }
        if let companion = companion(for: bubble) {
            selectCompanion(companion.id)
        }
    }

    /// Hand a conjoined intent to the oracle. While the course is held (⏸) the
    /// intent waits inside the Ægis; ▶ lets the wait fly. A typed prompt always
    /// runs — the hold governs the pantheon, never the user's own hand.
    private func startCourseTurn(intent: String) {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !paused else {
            pendingCourseIntents.append(trimmed)
            return
        }
        send(trimmed, keepingSuggestions: true)
    }

    /// Hold Pythia: conjoined suggestions accumulate instead of opening turns,
    /// and a *running* turn stops at its next step boundary (⏸) instead of racing
    /// ahead — the daemon keeps the chapter alive, so ▶ continues it.
    func pause() {
        paused = true
        guard busy else {
            heldTurn = false
            return
        }
        heldTurn = true
        statusText = "⏸ Gehalten — ▶ lässt den Faden weiterlaufen."
        Task { [weak self] in
            let held = await RubyBridge.shared.pauseTurn()
            await MainActor.run {
                guard let self else { return }
                // Nothing in flight to hold — the intent stays, the turn doesn't.
                if !held { self.heldTurn = false }
            }
        }
    }

    /// Release the hold: a held chapter continues (with anything woven in), else
    /// the waiting intentions fly as one course.
    func resume() {
        paused = false
        let waiting = pendingCourseIntents
        pendingCourseIntents = []
        if heldTurn {
            heldTurn = false
            statusText = nil
            let course = waiting.isEmpty ? nil : waiting.map { "• \($0)" }.joined(separator: "\n")
            Task { [weak self] in
                let released = if let course {
                    await RubyBridge.shared.weaveTurn(text: course)
                } else {
                    await RubyBridge.shared.resumeTurn()
                }
                await MainActor.run {
                    guard let self else { return }
                    // The chapter had closed on its own — the held intentions
                    // become their own turn instead of evaporating.
                    guard !released, !waiting.isEmpty else { return }
                    self.send(waiting.map { "• \($0)" }.joined(separator: "\n"), keepingSuggestions: true)
                }
            }
            return
        }
        guard !waiting.isEmpty else { return }
        send(waiting.map { "• \($0)" }.joined(separator: "\n"), keepingSuggestions: true)
    }

    func togglePause() { paused ? resume() : pause() }

    /// Tear the running turn: cooperative daemon interrupt (which also releases a
    /// held gate), dropped queue, a silenced veil. Everything already landed in
    /// the flow stays — only the unfinished chapter is closed by force.
    func stop() {
        let hadWork = busy || heldTurn || !queuedMessageIDs.isEmpty || !pendingCourseIntents.isEmpty
        turnGeneration += 1
        paused = false
        heldTurn = false
        queuedMessageIDs = []
        rebasedMessageIDs = []
        pendingCourseIntents = []
        busy = false
        streamingVisible = false
        streamingText = ""
        statusText = nil
        guard hadWork else { return }
        RubyBridge.shared.abort()
        closeOpenToolGroup()
        appendSystemMessage(kind: "interrupt",
                            data: ["message": "⏹ Turn abgebrochen — der Faden ist still."],
                            level: "info")
    }

    /// Intentions waiting behind the hold or the running turn — what ⏹ drops.
    var pendingCount: Int { queuedMessageIDs.count + pendingCourseIntents.count }

    /// The Ægis drafted a fresh course — surface it as a veil. A course change is
    /// a boundary in the thinking, not a chip.
    private func coursePlanDidLand(_ plan: String) {
        closeOpenToolGroup()
        var revelation = AegisRevelation()
        revelation.header = "Wir nehmen kurz Kurs auf…"
        revelation.body = plan
        revelation.summary = plan
        revelation.tags = AegisWidgetModel.shared.conjunction.map { "facet:\($0.companionID)" }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.aegis(revelation))
        }
        scheduleFlowSave()
    }

    /// Answer the agent's `ask_user` consultation
    /// the user's choice (confirm / select / free-form prompt).
    func respondToAskUser(_ prompt: AskUserPrompt, response: String) {
        activeAskUser = nil
        Task {
            try? await RubyBridge.shared.sendUserResponse(uuid: prompt.uuid, response: response)
        }
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
            // Aegis is the mind setting a new course — it never becomes a quiet
            // chip inside a tool group. Its `aegis_unveiled` status renders the
            // orientation as a full-width system veil instead.
            if name == "aegis" { break }
            if name == "run_command" {
                // The agent's run_command merges as a CLI chip *inside* the open
                // instrumenta group — one interface, no group-tearing.
                appendCliChip(args: instrumentaStringify(data["args"]), toolId: toolId)
            } else {
                appendTool(name, args: instrumentaStringify(data["args"]), uuid: uuid)
            }
        case "aegis_unveiled":
            appendAegisRevelation(data)
        case "tool_completed":
            let name = (data["tool"] ?? data["name"]) as? String ?? ""
            if name == "run_command" || name == "aegis" { break }  // aegis shown via aegis_unveiled
            completeTool(toolId: toolId, output: instrumentaStringify(data["result"]))
        case "user_message", "user_prompt":
            // The iOS companion sent its prompt through the shared æther — render
            // it as a user turn so the Mac panel shows the whole conversation, not
            // just the tool telemetry that followed.
            let content = (data["content"] ?? data["message"]) as? String ?? ""
            if !content.isEmpty {
                appendMessage(ChatMessage(role: "user", text: content, glyph: "✦"))
            }
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
            // A system notice is a durable voice in the transcript, not a
            // transient footer status that the next live update erases.
            appendSystemMessage(kind: kind, data: data, level: "error")
        case "peer_drift":
            appendSystemMessage(kind: kind, data: data, level: "warn")
        case "system_message", "info", "info_message":
            // The daemon's own voice (ÆtherLink spawns, thinking pauses,
            // `tell_user` notices) — woven into the flow at its chronological
            // position so it persists instead of evaporating from a footer.
            appendSystemMessage(kind: kind, data: data, level: "info")
        case "ask_user":
            // The agent is consulting the user — surface a modal dialog and pause
            // the turn until `respondToAskUser` pushes the answer back.
            let askMessage = data["message"] as? String ?? ""
            activeAskUser = AskUserPrompt(
                uuid: uuid ?? "",
                type: data["type"] as? String ?? "prompt",
                message: askMessage,
                options: data["options"] as? [String] ?? []
            )
            // Ring the bell so the question is *felt*, and raise a system
            // notification through the Ægis so it is *seen* even when the editor
            // window is not frontmost. The chime is permission-free; the
            // notification grant lives on the shield.
            NSSound(named: NSSound.Name("Glass"))?.play()
            let announceTitle = "Pythia seeks your counsel"
            let announceBody = String(askMessage.prefix(180))
            Task {
                _ = await AegisClient.shared.announce(title: announceTitle, body: announceBody)
            }
        default:
            // Task-runner frames (task_started, task_step_completed, task_updated,
            // task_completed, task_log_added, …) are intentionally *not* rendered
            // here. A task's phase-by-phase progress belongs to the ⚗️ Magnum Opus
            // panel, which polls `task_detail` live — the chat flow stays clean and
            // the step phases never surface as JSON in the transcript.
            if InstrumentaStatus.statusKinds.contains(kind) {
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

    /// Aegis surfaces as its own flow entry — a prominent context-shift veil,
    /// never a chip buried in a tool group. It closes any open tool run first:
    /// setting a new course is a hard boundary in the thinking.
    private func appendAegisRevelation(_ data: [String: Any]) {
        closeOpenToolGroup()
        var revelation = AegisRevelation()
        if let msg = data["message"] as? String {
            revelation.header = InstrumentaStatus.plainText(fromHTML: msg)
        }
        // The daemon ships both the rendered HTML and the raw markdown — render
        // the markdown so headings, bold and code blocks keep their shape.
        if let raw = data["raw"] as? String, !raw.isEmpty {
            revelation.body = raw
        } else if let content = data["content"] as? String {
            revelation.body = InstrumentaStatus.plainText(fromHTML: content)
        }
        if let tags = data["tags"] as? [String] {
            revelation.tags = tags
        } else if let tagString = data["tags"] as? String, !tagString.isEmpty {
            revelation.tags = tagString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        revelation.thinking = data["thinking"] as? String
        revelation.temperature = (data["temperature"] as? NSNumber)?.doubleValue
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.aegis(revelation))
        }
        scheduleFlowSave()
        Task { await AegisWidgetModel.shared.refresh() }
    }

    /// A system notice (error / drift warning) woven into the timeline at its
    /// chronological position. It closes any open tool run first — the æther
    /// speaking is a boundary — then persists as a full-width veil instead of a
    /// transient footer status.
    private func appendSystemMessage(kind: String, data: [String: Any], level: String) {
        let raw = (data["message"] ?? data["error"]) as? String ?? ""
        let text = InstrumentaStatus.plainText(fromHTML: raw)
        guard !text.isEmpty else { return }
        closeOpenToolGroup()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.system(SystemMessage(text: text, level: level, kind: kind)))
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
        let (status, detail) = InstrumentaStatus.mergeText(kind: kind, data: data)
        if let status { chip.status = status }
        if let detail { chip.detail = detail }
        if let rawMessage = data["message"] as? String, !rawMessage.isEmpty {
            chip.message = InstrumentaStatus.plainText(fromHTML: rawMessage)
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
        // Reassign the whole set — mutating a @Published value type in place
        // (`.insert`/`.remove`) can miss `objectWillChange` when wrapped in a
        // transaction, so the minimized chip would never unfold. A clean
        // reassignment guarantees the change is observed.
        var next = expandedChipIDs
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        expandedChipIDs = next
    }
}

// MARK: - Pythia panel

/// The three faces of the trailing pane: Pythia's chat, Salomo's Siegel, and
/// the Magnum Opus orchestration view.
private enum PythiaMode { case pythia, siegel, magnumOpus }

struct PythiaPanel: View {
    @ObservedObject var model: PythiaChatModel
    /// Top inset for the header row. 28 clears the traffic lights when Pythia
    /// sits at the window top (oracle-only flip face); the trailing inspector
    /// passes a larger value that clears the full-width tab strip instead.
    var topClearance: CGFloat = 28
    /// Flip the whole window to oracle-only (fullscreen Pythia), when hosted by
    /// the editor chrome. Standalone windows leave these nil and show no controls.
    var onFlip: (() -> Void)? = nil
    /// Hide (collapse) the trailing Pythia inspector.
    var onClosePythia: (() -> Void)? = nil
    @ObservedObject private var aetherContext = AetherContext.shared
    @State private var themeRevision = 0
    @State private var mode: PythiaMode = .pythia
    /// Measured height of the whole pane — the budget the unfolded Aegis mirror
    /// may draw from without starving the message list.
    @State private var paneHeight: CGFloat = 0

    /// The active theme's chamber palette — mirrors the code editor's chrome.
    private var palette: PythiaPalette { ThemeRegistry.shared.current.pythia }

    var body: some View {
        let palette = self.palette
        let _ = themeRevision
        Group {
            if mode == .siegel {
                SolomonPanel()
            } else if mode == .magnumOpus {
                MagnumOpusPanel()
            } else {
                MessageList(model: model)
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            HStack(spacing: 6) {
              PanelModePicker(mode: $mode)
              if mode == .pythia {
                  CompanionPicker(model: model)
              }
              Spacer(minLength: 0)
              inspectorControls
            }
            .padding(.horizontal, 10)
            .padding(.top, topClearance)  // titlebar clearance (traffic lights row)
            .padding(.bottom, 2)

            if aetherContext.root != nil {
                HStack(spacing: 6) {
                    ContextPill(context: aetherContext)
                    Spacer(minLength: 0)
                    debugGlyphButton
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }

            Divider().opacity(0.4)

          }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
          if mode == .pythia {
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

              AegisWidgetView(
                  maxDetailHeight: AegisWidgetView.detailCap(forPaneHeight: paneHeight)
              )
                  .padding(.horizontal, 10)
                  .padding(.top, 6)
                  .transition(.opacity.combined(with: .move(edge: .bottom)))

              StreamingFooter(model: model)
                  .padding(.horizontal, 10)
                  .padding(.top, 4)

              InputBar(model: model)
                  .padding(10)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.recoverCard == nil)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.companionBubbles)
          }
        }
        .onAppear {
            model.restoreSessionIfNeeded()
            Task { await AegisWidgetModel.shared.refresh() }
        }
        .onChange(of: aetherContext.root) { oldRoot, newRoot in
            model.contextDidChange(from: oldRoot, to: newRoot)
        }
        .environment(\.pythiaPalette, palette)
        .tint(palette.accentColor)
        .onReceive(NotificationCenter.default.publisher(for: ThemeSettings.didChangeNotification)) { _ in
            themeRevision += 1
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .sheet(item: $model.activeAskUser) { prompt in
            AskUserDialog(prompt: prompt) { response in
                model.respondToAskUser(prompt, response: response)
            }
        }
    }

    /// Liquid-glass glyph button toggling the Æther Debug window (daemon logs)
    /// — hidden chrome, revealed only when a project context breathes.
    private var debugGlyphButton: some View {
        Button {
            AppScene.shared.toggleDebugLog()
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

    /// Pythia's own top-right chrome: flip to oracle-only (fullscreen) and hide
    /// the inspector. Rendered only when the editor chrome wires the closures in.
    @ViewBuilder private var inspectorControls: some View {
        if onFlip != nil || onClosePythia != nil {
            HStack(spacing: 2) {
                if let onFlip {
                    Button(action: onFlip) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accentColor)
                    .help("Oracle Only (fullscreen)")
                }
                if let onClosePythia {
                    Button(action: onClosePythia) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accentColor)
                    .help("Close Pythia")
                }
            }
            .padding(2)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

}

// MARK: - Panel mode picker

/// A quiet three-face toggle: Pythia (the chat), Siegel (Salomo's temple) and
/// the Magnum Opus (orchestration).
private struct PanelModePicker: View {
    @Binding var mode: PythiaMode
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.pythia, glyph: "🐍", help: "Pythia — das Orakel")
            modeButton(.siegel, glyph: "👑", help: "Siegelkabinett — Salomos Tempel")
            modeButton(.magnumOpus, glyph: "⚗️", help: "Magnum Opus — Orchestrierung")
        }
        .padding(2)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
    }

    private func modeButton(_ m: PythiaMode, glyph: String, help: String) -> some View {
        Button {
            mode = m
        } label: {
            Text(glyph)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
                .background(mode == m ? palette.accentColor.opacity(0.25) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Context pill

/// The active project's identity — a quiet glyph + name that lets the window
/// advertise *which* æther it is currently breathing. "ICH bin der ÆTHER."
private struct ContextPill: View {
    @ObservedObject var context: AetherContext
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        Button {
            AppScene.shared.openProjectSettings(contextTab: true)
        } label: {
            HStack(spacing: 5) {
                Text("◈")
                    .font(.system(size: 10))
                    .foregroundStyle(context.configPath != nil ? palette.accentColor : Color.secondary)
                Text(context.name ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help("Project settings — Context (click to configure ÆtherLink relations)")
    }
}

// MARK: - Companion picker

private struct CompanionPicker: View {
    @ObservedObject var model: PythiaChatModel
    @ObservedObject private var bridge = RubyBridge.shared
    @Environment(\.pythiaPalette) private var palette
    @State private var showMenu = false
    /// Companion whose glyph was clicked without a pending suggestion — the
    /// "direkt ansprechen" prompt anchors here instead of silently toggling it off.
    @State private var promptedCompanion: Companion? = nil

    /// The pantheon as the daemon knows it — one roster, two worlds. Falls back
    /// to the local copy until the first `ready` frame arrives; Pythia herself
    /// is always first (the wire roster carries only the companions).
    private var companions: [Companion] {
        var list = bridge.companionRoster.map {
            Companion(id: $0.key, glyph: $0.glyph, label: $0.name, title: $0.name,
                      trigger: $0.trigger, grant: $0.grant, reach: $0.reach, tools: $0.tools)
        }
        if !list.contains(where: { $0.id == "pythia" }) {
            list.insert(Companion(id: "pythia", glyph: "🐍", label: "Pythia", title: "Pythia",
                                  trigger: "Standard-Orakel — das Zuhause aller Stimmen"), at: 0)
        }
        return list.isEmpty ? pythiaCompanions : list
    }

    /// Only Pythia and the activated companions sit in the bar. The rest of the
    /// pantheon sleeps behind the veil button — found, described and switched on
    /// in the companion menu.
    private var visibleCompanions: [Companion] {
        companions.filter { $0.id == "pythia" || model.isCompanionActive($0.id) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(visibleCompanions) { companion in
                        pickerButton(for: companion)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)

            // The veil button — the rest of the pantheon: info, configuration,
            // activation. One glyph, many sleeping voices.
            Button {
                showMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                    .foregroundStyle(palette.foregroundColor.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Begleiter verwalten")
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                CompanionMenu(model: model, companions: companions)
                    .environment(\.pythiaPalette, palette)
            }
        }
    }

    /// One glyph, two gestures: a click conjoins the companion's pending
    /// suggestion (or summons the bare facet) into the shared Aegis course, a
    /// right-click offers direct speech plus activate/deactivate. Pythia herself
    /// is the immutable home voice.
    @ViewBuilder
    private func pickerButton(for companion: Companion) -> some View {
        let isPythia = companion.id == "pythia"
        let isDirect = model.companionID == companion.id
        let isActive = isPythia || model.isCompanionActive(companion.id)
        let suggestion = suggestion(for: companion)

        Button {
            if isPythia {
                model.selectCompanion("pythia")
            } else if let suggestion {
                // The companion offered a follow-up: the click conjoins that
                // suggestion into the shared Aegis course.
                model.conjoinBubble(suggestion)
            } else {
                // No pending suggestion: summon the bare facet into the team.
                model.conjoinCompanion(companion)
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
        .help(helpText(for: companion, isPythia: isPythia, isActive: isActive, isDirect: isDirect, hasSuggestion: suggestion != nil))
        .popover(isPresented: directPromptBinding(for: companion), arrowEdge: .bottom) {
            directPrompt(for: companion)
        }
        .contextMenu {
            if !isPythia {
                Button(isDirect ? "✓ \(companion.label)" : "Direkt ansprechen") {
                    model.selectCompanion(companion.id)
                }
                Divider()
                Button(isActive ? "Deaktivieren" : "Aktivieren") {
                    model.toggleCompanion(companion.id)
                }
            }
        }
    }

    private func helpText(for companion: Companion, isPythia: Bool, isActive: Bool, isDirect: Bool, hasSuggestion: Bool) -> String {
        if isPythia {
            return isDirect ? "Pythia — Standard-Orakel" : "Zu Pythia zurückkehren"
        }
        let state = isActive ? "aktiv" : "inaktiv"
        let voice = isDirect ? " · du sprichst direkt" : ""
        let click = hasSuggestion ? "Klick: in den Kurs aufnehmen" : "Klick: Facette dazurufen"
        return "\(companion.label) (\(state))\(voice)\n\(click) · Rechtsklick: aktivieren/deaktivieren"
    }

    /// The pending suggestion this companion offered in the latest reply, matched
    /// by glyph (unique across the pantheon). A matching bubble turns the click
    /// into a dialog continuation.
    private func suggestion(for companion: Companion) -> CompanionBubble? {
        model.companionBubbles.first { $0.glyph == companion.glyph }
    }

    /// Per-companion presentation binding: only the clicked glyph's popover opens.
    private func directPromptBinding(for companion: Companion) -> Binding<Bool> {
        Binding(
            get: { promptedCompanion?.id == companion.id },
            set: { if !$0 { promptedCompanion = nil } }
        )
    }

    /// The extra prompt a glyph opens when it carries no suggestion — a single
    /// "direkt ansprechen" action. Speaking to the voice, not toggling it off.
    private func directPrompt(for companion: Companion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(companion.glyph).font(.system(size: 12))
                Text(companion.displayName)
                    .font(.system(size: 12, weight: .semibold))
            }
            Button {
                promptedCompanion = nil
                model.selectCompanion(companion.id)
            } label: {
                Label("Direkt ansprechen", systemImage: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(palette.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 200)
    }
}

// MARK: - Companion menu (veil of the pantheon)

/// The extra menu: every companion with full info, configuration and activation.
/// The bar above shows only the activated; here the rest of the pantheon is
/// found, described, and switched on.
private struct CompanionMenu: View {
    @ObservedObject var model: PythiaChatModel
    let companions: [Companion]
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("✦").font(.system(size: 12)).foregroundStyle(palette.accentColor)
                Text("Begleiter").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.activeCompanions.count) aktiv")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(companions) { companion in
                        CompanionMenuRow(companion: companion, model: model)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 380, height: 500)
        .background(palette.backgroundColor)
    }
}

private struct CompanionMenuRow: View {
    let companion: Companion
    @ObservedObject var model: PythiaChatModel
    @Environment(\.pythiaPalette) private var palette

    private var isPythia: Bool { companion.id == "pythia" }
    private var isActive: Bool { isPythia || model.isCompanionActive(companion.id) }
    private var isDirect: Bool { model.companionID == companion.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                Text(companion.glyph)
                    .font(.system(size: 17))
                    .frame(width: 30, height: 30)
                    .background(
                        isActive ? palette.accentColor.opacity(0.16) : Color.gray.opacity(0.12),
                        in: Circle()
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isDirect ? palette.accentColor.opacity(0.95) : .clear,
                            lineWidth: 1.2
                        )
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(companion.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(companion.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isPythia {
                    Text("Zuhause")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(palette.accentColor.opacity(0.16)))
                        .foregroundStyle(palette.accentColor)
                } else {
                    Toggle("", isOn: Binding(
                        get: { model.isCompanionActive(companion.id) },
                        set: { _ in model.toggleCompanion(companion.id) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
            }

            if !companion.trigger.isEmpty {
                Text(companion.trigger)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let chips = ([companion.grant, companion.reach].filter { !$0.isEmpty }) + companion.tools
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(palette.foregroundColor.opacity(0.06)))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !isPythia {
                Button {
                    model.selectCompanion(companion.id)
                } label: {
                    HStack(spacing: 4) {
                        if isDirect {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text(isDirect ? "Du sprichst direkt" : "Direkt sprechen")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            isDirect ? palette.accentColor.opacity(0.18) : palette.accentColor.opacity(0.08)
                        )
                    )
                    .foregroundStyle(isDirect ? palette.accentColor : palette.foregroundColor.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? palette.foregroundColor.opacity(0.045) : Color.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive ? palette.accentColor.opacity(0.35) : palette.foregroundColor.opacity(0.08),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - CLI block

/// The unified shell block woven into the flow — produced both by the user's `$`
/// prompt and by the agent's `run_command` tool. Two hands, one interface.
private struct CliBlock: View {
    let entry: CliEntry
    var level: CompactionLevel = .expanded
    @Environment(\.pythiaPalette) private var palette
    @State private var expanded = true

    /// Compact and micro tiers never unfold — they stay a one-line shell, the
    /// far-past command collapsed to a whisper like its zipped history.
    private var canExpand: Bool { level < .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Text("$")
                        .font(.system(size: level == .micro ? 9 : 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accentColor)
                    Text(highlightCode(entry.command, language: "shell"))
                        .font(.system(size: level == .micro ? 9 : 11, design: .monospaced))
                        .foregroundStyle(level == .micro ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if entry.done {
                        Image(systemName: entry.exitStatus == 0 ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(entry.exitStatus == 0 ? Color.secondary : Color.red.opacity(0.8))
                    } else if level < .compact {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canExpand, expanded, !entry.output.isEmpty {
                CliOutputPane(text: entry.output)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, level == .micro ? 3 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Timeline rail (git-log graph)

/// Lane classification of a flow node — drives the gutter dot's colour. The
/// whole flow becomes a commit graph: prompts, oracle output, instrumenta calls
/// and shell blocks each land as an identifiable commit, not a nameless bubble.
private enum FlowNodeKind {
    case user, assistant, tool, cli, aegis, system

    static func forEntry(_ entry: FlowEntry) -> FlowNodeKind {
        switch entry {
        case .message(let m): return m.role == "user" ? .user : .assistant
        case .toolGroup: return .tool
        case .cli: return .cli
        case .aegis: return .aegis
        case .system: return .system
        }
    }
}

/// How a commit joins the graph. A queued interjection forks off the running
/// turn; once answered it rebases back onto the linear trunk.
private enum FlowRailMode {
    case normal, fork, rebased
}

/// The left gutter rail: a commit dot on a connecting spine, like `git log
/// --graph`. Cheap to render (a handful of stroked paths per visible row), so
/// it stays smooth even with many windows sharing one live flow.
private struct FlowRail: View {
    @Environment(\.pythiaPalette) private var palette
    let kind: FlowNodeKind
    let mode: FlowRailMode
    let isFirst: Bool
    let isLast: Bool

    private var nodeColor: Color {
        switch kind {
        case .user: return palette.accentColor
        case .assistant: return palette.foregroundColor.opacity(0.55)
        case .tool: return .cyan.opacity(0.85)
        case .cli: return .mint.opacity(0.9)
        case .aegis: return .indigo.opacity(0.85)
        case .system: return .orange.opacity(0.8)
        }
    }

    private var spineColor: Color { palette.foregroundColor.opacity(0.16) }
    private let nodeY: CGFloat = 13
    private let nodeDiameter: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .top) {
                // Spine below the node — continues the lane to the next commit.
                // Starts at the dot's lower rim so the lane reads unbroken.
                if !isLast {
                    spineLine(from: nodeY + nodeDiameter / 2,
                              length: height - nodeY - nodeDiameter / 2,
                              dashed: false)
                }
                // Spine above the node — skipped for the very first commit;
                // dashed for a fork/rebased so the branch point reads. Ends at
                // the dot's upper rim: no gap between lane and commit.
                if !isFirst {
                    spineLine(from: 0, length: nodeY - nodeDiameter / 2,
                              dashed: mode != .normal)
                }
                // The commit dot.
                Circle()
                    .fill(nodeColor)
                    .frame(width: nodeDiameter, height: nodeDiameter)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                    .offset(y: nodeY - nodeDiameter / 2)
                // Fork elbow for a queued interjection — the branch stub.
                if mode == .fork {
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: nodeY))
                        p.addLine(to: CGPoint(x: 16, y: nodeY))
                    }
                    .stroke(spineColor, lineWidth: 1.5)
                }
            }
            .frame(width: 16, alignment: .top)
        }
        .frame(width: 16)
    }

    private func spineLine(from y: CGFloat, length: CGFloat, dashed: Bool) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 8, y: y))
            p.addLine(to: CGPoint(x: 8, y: y + length))
        }
        .stroke(spineColor, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [2, 3] : []))
    }
}

/// One commit row: a short git-style hash, the graph rail, and the node content.
private struct FlowCommitRow<Content: View>: View {
    let entry: FlowEntry
    let isFirst: Bool
    let isLast: Bool
    let isQueued: Bool
    let isRebased: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            FlowRail(
                kind: FlowNodeKind.forEntry(entry),
                mode: railMode,
                isFirst: isFirst,
                isLast: isLast
            )
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // Breathing room between commits lives INSIDE the row, so the
                // rail's spine runs through it uninterrupted (rows touch).
                .padding(.bottom, 8)
        }
    }

    private var railMode: FlowRailMode {
        if isQueued { return .fork }
        if isRebased { return .rebased }
        return .normal
    }
}


private struct MessageList: View {
    @ObservedObject var model: PythiaChatModel
    @State private var breathing = false
    /// True when the reader is parked at the live edge — autoscroll may follow.
    @State private var isAtBottom = true
    /// True when the reader is at the very top — the trigger to pull older pages.
    @State private var isAtTop = false

    /// How far the true bottom may drift below the visible edge before we
    /// detach and surface the "jump to bottom" arrow.
    private let proximityThreshold: CGFloat = 48
    /// How near the top edge counts as "at the top" for older-page loading.
    private let topProximityThreshold: CGFloat = 40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if model.hasMoreOlder {
                        olderHistoryHint
                    }
                    if model.flow.isEmpty && !model.streamingVisible {
                        emptyState
                    }
                    ForEach(Array(model.flow.enumerated()), id: \.element.id) { index, entry in
                        let level = CompactionLevel.level(distanceFromEnd: model.flow.count - 1 - index)
                        FlowCommitRow(
                            entry: entry,
                            isFirst: index == 0,
                            isLast: index == model.flow.count - 1 && !model.streamingVisible,
                            isQueued: isQueued(entry),
                            isRebased: isRebased(entry)
                        ) {
                            switch entry {
                            case .message(let message):
                                MessageRow(message: message,
                                           level: level,
                                           queued: model.queuedMessageIDs.contains(message.id),
                                           rebased: model.rebasedMessageIDs.contains(message.id),
                                           onRetry: (index == model.flow.count - 1 && !model.busy && PythiaChatModel.isRetryableError(message.text))
                                               ? { model.retryLastTurn() } : nil)
                            case .toolGroup(let group):
                                ToolGroupView(group: group,
                                              level: level,
                                              expandedChipIDs: model.expandedChipIDs,
                                              onToggle: { model.toggleToolGroup(group.id) },
                                              onToggleChip: { model.toggleToolChip($0) })
                            case .cli(let cli):
                                CliBlock(entry: cli, level: level)
                            case .aegis(let aegis):
                                AegisBlock(revelation: aegis, level: level)
                            case .system(let system):
                                SystemMessageRow(message: system, level: level)
                            }
                        }
                        .id(entry.id)
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Near the top edge → older history is within reach. Edge-triggered
                // in the action so a single scroll-up pulls exactly one page.
                geometry.contentOffset.y <= topProximityThreshold
            } action: { _, atTop in
                let wasAtTop = isAtTop
                isAtTop = atTop
                if atTop && !wasAtTop {
                    model.loadOlderPage(proxy)
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
            .onAppear {
                // On first open, park at the newest entry — the reader never
                // opens into the middle of an old chapter. One runloop hop so
                // the restored page has committed before anchoring to it.
                isAtBottom = true
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
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

    /// True when this commit is a queued interjection (forked off a running turn).
    private func isQueued(_ entry: FlowEntry) -> Bool {
        if case .message(let m) = entry { return model.queuedMessageIDs.contains(m.id) }
        return false
    }

    /// True when this commit was queued and has since rebased onto the trunk.
    private func isRebased(_ entry: FlowEntry) -> Bool {
        if case .message(let m) = entry { return model.rebasedMessageIDs.contains(m.id) }
        return false
    }

    /// Whisper-quiet header shown only while older history exists beyond the
    /// loaded window — turns into a spinner while a page is being pulled in.
    private var olderHistoryHint: some View {
        HStack(spacing: 6) {
            if model.isLoadingOlder {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 11))
            }
            Text(model.isLoadingOlder ? "Loading earlier…" : "Earlier messages")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
    var level: CompactionLevel = .expanded
    var plain = false
    var queued = false
    var rebased = false
    /// Non-nil when this message is a transient failure (server overload / rate
    /// limit) and the reader may re-issue the turn in one click.
    var onRetry: (() -> Void)? = nil
    @State private var showThinking = false
    /// Lifts a degraded (compact/micro) message back to full markdown on demand,
    /// so the decay law never makes a far-past answer unreadable.
    @State private var expanded = false
    @Environment(\.pythiaPalette) private var palette

    private var isUser: Bool { message.role == "user" }
    private var isCompanionVoice: Bool { !(message.speakerName ?? "").isEmpty }

    var body: some View {
        if isUser {
            userRow
        } else if isCompanionVoice {
            companionSpeech
        } else {
            pythiaFlow
        }
    }

    /// The user's own prompt — a right-aligned speech bubble with a tail, an
    /// accent-tinted surface and a small "Du" label. Distinct from the oracle's
    /// borderless flow, so the human voice reads as its own presence.
    private var userRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Du")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.accentColor.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.accentColor.opacity(0.28), lineWidth: 0.5))
                    .padding(.trailing, 3)
                bubble
                    .frame(maxWidth: 300, alignment: .trailing)
                if queued {
                    queuedBadge
                } else if rebased {
                    rebasedBadge
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Pythia's own voice — the stream of consciousness. It flows directly into
    /// the base as text, with no bubble and no glyph chrome; only the reasoning
    /// block (when present) reveals the oracle's private thinking first.
    private var pythiaFlow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if level == .expanded, let reasoning = message.reasoning, !reasoning.isEmpty, !plain {
                ThinkingBlock(text: reasoning, isExpanded: $showThinking)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            bodyText
                .padding(.vertical, 2)
                .padding(.leading, 4)
            if let onRetry {
                retryButton(onRetry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// A quiet "Continue" affordance offered for a transient failure (server
    /// overload / rate limit). Retrying is a re-issue, not a new prompt — the
    /// user's word is already in the conduit.
    private func retryButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Continue", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.accentColor.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(palette.accentColor.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accentColor)
        .padding(.leading, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The message body at the row's compaction level. The live edge renders full
    /// markdown; medium drops only the reasoning chrome; compact clamps to a plain
    /// three-line preview; micro collapses to a single horizontal-ellipsis line —
    /// the same decay law that zips token history, made visible. Degraded tiers
    /// keep a "more" affordance to re-expand anything that got cut off.
    @ViewBuilder
    private var bodyText: some View {
        switch level {
        case .expanded, .medium:
            fullBody
        case .compact, .micro:
            if expanded {
                expandedDegraded
            } else {
                collapsedDegraded
            }
        }
    }

    /// Full markdown at the oracle's own width — shared by the live edge and the
    /// on-demand re-expansion of a degraded message.
    private var fullBody: some View {
        MarkdownBody(text: message.text, plain: plain)
            .environment(\.openURL, OpenURLAction { url in
                // AI-authored markdown may embed arbitrary URL schemes;
                // allow only http/https to leave the app.
                (url.scheme == "https" || url.scheme == "http") ? .systemAction : .handled
            })
    }

    /// Whether the degraded preview was actually cut off — short single-line
    /// replies ("done") stay quiet without a pointless expander.
    private var canExpand: Bool {
        level >= .compact && (message.text.count > 120 || message.text.contains("\n"))
    }

    private var degradedFontSize: CGFloat { level == .compact ? 12 : 10 }
    private var degradedForeground: AnyShapeStyle {
        level == .compact ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }

    private var collapsedDegraded: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.oneLinePreview)
                .font(.system(size: degradedFontSize))
                .foregroundStyle(degradedForeground)
                .lineLimit(level == .compact ? 3 : 1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if canExpand {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded = true }
                } label: {
                    Label("more", systemImage: "arrow.down.forward.and.arrow.up.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accentColor)
            }
        }
    }

    private var expandedDegraded: some View {
        VStack(alignment: .leading, spacing: 6) {
            fullBody
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded = false }
            } label: {
                Label("less", systemImage: "arrow.up.backward.and.arrow.down.forward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accentColor)
        }
    }

    /// A companion speaking through Pythia's turn — a real speech bubble with
    /// the speaker's glyph + name in a small header, distinct from the flowing
    /// base text of the oracle's own voice.
    private var companionSpeech: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(message.glyph)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                Text(message.speakerName ?? "")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.accentColor)
                    .padding(.leading, 12)
                bodyText
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: LeftTailBubbleShape())
                    .overlay(
                        LeftTailBubbleShape()
                            .stroke(.white.opacity(0.11), lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var bubble: some View {
        bodyText
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    // Translucent glass body.
                    RightTailBubbleShape().fill(.ultraThinMaterial)
                    // Accent tint — brighter toward the top, denser at the base,
                    // so the volume reads as lit glass, not a flat card.
                    RightTailBubbleShape().fill(
                        LinearGradient(colors: [
                            palette.accentColor.opacity(0.34),
                            palette.accentColor.opacity(0.16),
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    // Specular kiss along the top edge — the "liquid" sheen.
                    RightTailBubbleShape().fill(
                        LinearGradient(colors: [
                            .white.opacity(0.32),
                            .white.opacity(0.0),
                        ], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55))
                    )
                }
            )
            .overlay(
                RightTailBubbleShape()
                    .stroke(
                        LinearGradient(colors: [
                            .white.opacity(0.5),
                            palette.accentColor.opacity(0.5),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: palette.accentColor.opacity(0.45), radius: 12, x: 0, y: 3)
            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 1)
    }

    /// A quiet "wartet" trace for a message queued behind a running turn — the
    /// fork marker. It dissolves into the "rebased" trace once its turn begins.
    private var queuedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 8, weight: .semibold))
            Text("wartet")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    /// The lasting confluence trace: this message forked off a running turn and
    /// has since rebased onto the linear trunk. Keeps the merge legible.
    private var rebasedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 8, weight: .semibold))
            Text("rebased")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A system notice — the daemon's own voice (error, drift, info). A quiet
/// full-width veil, slimmer than Aegis: a level-tinted glyph + the notice text,
/// persisted in the timeline rather than evaporating from a footer status.
struct SystemMessageRow: View {
    let message: SystemMessage
    var level: CompactionLevel = .expanded
    @Environment(\.pythiaPalette) private var palette

    private var glyph: String {
        switch message.level {
        case "error": return "❌"
        case "warn":  return "⚠️"
        default:      return "💬"
        }
    }

    private var tint: Color {
        switch message.level {
        case "error": return .red
        case "warn":  return .orange
        default:      return .teal
        }
    }

    private var lineLimit: Int? {
        switch level {
        case .expanded: return nil
        case .medium:   return 2
        case .compact:  return 1
        case .micro:    return 1
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(glyph)
                .font(.system(size: level == .micro ? 9 : 11))
                .frame(width: level == .micro ? 16 : 22, height: level == .micro ? 16 : 22)
                .background(tint.opacity(0.14), in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            Text(message.text)
                .font(.system(size: level == .micro ? 9 : 11, weight: .medium))
                .foregroundStyle(level == .micro ? .tertiary : .primary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, level == .micro ? 3 : 7)
        .background(
            LinearGradient(colors: [tint.opacity(0.12), palette.complementaryColor.opacity(0.04), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// Aegis — the oracle setting a new course. A full-width system veil with the
/// prominence of an AI message, not a quiet tool chip: it marks a context shift
/// in the model's thinking (orientation, thinking depth, temperature, notes).
struct AegisBlock: View {
    let revelation: AegisRevelation
    var level: CompactionLevel = .expanded
    @State private var notesExpanded = false

    private var summaryText: String {
        revelation.summary.isEmpty ? revelation.body : revelation.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if level < .micro, !summaryText.isEmpty {
                summarySection
            }

            if level == .expanded, !revelation.notes.isEmpty {
                notesSection
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, level == .micro ? 3 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.indigo.opacity(0.22), lineWidth: 0.5))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.indigo)
            Text(revelation.header)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.indigo)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let thinking = revelation.thinking {
                Text("thinking: \(thinking)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let temperature = revelation.temperature {
                Text("temp \(String(format: "%.1f", temperature))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The new orientation summary — the most prominent element of the veil.
    /// A labeled, glowing, accent-barred block so it reads as "a new course",
    /// not a note.
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("NEW COURSE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .kerning(0.8)
            }
            .foregroundStyle(.indigo)

            prominentSummaryText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            LinearGradient(colors: [.indigo.opacity(0.18), .indigo.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [.indigo, .indigo.opacity(0.35)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 3.5)
                .padding(.vertical, 9)
                .shadow(color: .indigo.opacity(0.55), radius: 5, y: 0)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.indigo.opacity(0.24), lineWidth: 0.5))
        .shadow(color: .indigo.opacity(0.20), radius: 12, y: 4)
    }

    /// The summary rendered larger and bolder than normal prose — the "new
    /// course" must read like a headline, not another line of chat.
    private var prominentSummaryText: some View {
        let attributed = (try? AttributedString(markdown: summaryText,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(summaryText)
        return Text(attributed)
            .font(level == .compact ? .system(size: 12) : summaryFont)
            .lineSpacing(3.5)
            .lineLimit(level == .compact ? 2 : nil)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .foregroundStyle(level == .compact ? .secondary : .primary)
            .environment(\.openURL, OpenURLAction { url in
                if FileLinkResolver.open(url) { return .handled }
                return (url.scheme == "https" || url.scheme == "http") ? .systemAction : .handled
            })
    }

    /// The theme's prose family (Syne for Argonaut) in a heavier, larger cut.
    private var summaryFont: Font {
        let base = ThemeRegistry.shared.current.pythia.proseFont
        let size = base.pointSize + 2.5
        if let fam = base.familyName, let f = NSFont(name: fam, size: size) {
            return Font(NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask))
        }
        return .system(size: size, weight: .semibold)
    }

    /// Recalled notes, collapsed into a memory drawer by default.
    private var notesSection: some View {
        DisclosureGroup(isExpanded: $notesExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(revelation.notes) { note in
                    AegisNoteCard(note: note)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .semibold))
                Text("Memories")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("\(revelation.notes.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.indigo.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(.indigo)
        }
        .tint(.indigo.opacity(0.8))
    }
}

/// One recalled note inside the Aegis veil, styled like a Mnemosyne memory —
/// lotus, id, content, tag capsules and filetype-decorated origin links.
private struct AegisNoteCard: View {
    let note: AegisNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🪷")
                    .font(.system(size: 10))
                    .opacity(0.7)
                echoDots
                Spacer(minLength: 0)
                if note.id != 0 {
                    Text("#\(note.id)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }

            MarkdownBody(text: note.content)
                .environment(\.markdownBodyScale, noteMarkdownScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !note.tags.isEmpty || !note.links.isEmpty || !note.createdAt.isEmpty {
                Rectangle()
                    .fill(LinearGradient(colors: [.indigo.opacity(0.22), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 0.5)
                    .opacity(0.6)
            }
            if !note.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(note.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.indigo.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(.indigo.opacity(0.18), lineWidth: 0.5))
                        }
                    }
                }
            }
            if !note.links.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(note.links, id: \.self) { link in
                        FileLinkButton(path: link, accent: .indigo)
                    }
                }
            }
            if !note.createdAt.isEmpty {
                Text(note.createdAt)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.indigo.opacity(0.10), lineWidth: 0.5))
    }

    /// Memory score rendered as echo dots — mirrors the Mnemosyne memory card
    /// so a recalled note inside the veil reads as a memory, not a callout.
    @ViewBuilder private var echoDots: some View {
        if note.score > 0 {
            let n = min(max(Int(note.score.rounded()), 1), 5)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < n ? Color.indigo.opacity(0.85) : Color.secondary.opacity(0.14))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }
}

/// A collapsible cluster of *consecutive* instrumenta calls, rendered inline
/// at its chronological position in the flow. Independent from any footer.
struct ToolGroupView: View {
    let group: ToolGroup
    var level: CompactionLevel = .expanded
    /// Chips the user unfolded inside the group. Held by the hosting model so
    /// Pythia's and Salomo's ledgers share one expansion vocabulary.
    let expandedChipIDs: Set<UUID>
    let onToggle: () -> Void
    let onToggleChip: (UUID) -> Void
    @Namespace private var morph
    private var morphID: String { "group-\\(group.id)" }

    var body: some View {
        ZStack(alignment: .top) {
            if group.expanded {
                expandedGroup
                    .matchedGeometryEffect(id: morphID, in: morph)
                    .transition(.opacity)
            } else {
                collapsedGroup
                    .matchedGeometryEffect(id: morphID, in: morph)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: group.expanded)
    }

    /// Collapsed: a quiet one-liner naming the newest action — it transmorphs
    /// into the unfolded cluster instead of lingering beside it.
    private var collapsedGroup: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                onToggle()
            }
        } label: {
            HStack(spacing: 5) {
                if level < .compact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                if group.tools.count > 1 {
                    Text("\(group.tools.count) ·")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let last = group.tools.last {
                    MinifiedInstrumentLabel(chip: last, level: level)
                }
                Spacer(minLength: 0)
                if group.allDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else if level < .compact {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Unfolded: the cluster's own header plus its chips, sharing one
    /// matched-geometry frame with the collapsed one-liner.
    private var expandedGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                    onToggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text(group.tools.count == 1 ? "1 Instrument" : "\(group.tools.count) Instrumente")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(group.tools) { chip in
                ToolChipRow(chip: chip,
                            level: level,
                            isExpanded: expandedChipIDs.contains(chip.id),
                            onToggle: { onToggleChip(chip.id) })
            }
        }
    }
}

/// Minified rendering of a single instrument — the original horologium message
/// (or a synthesized fallback) as a compact, information-rich line: path, byte
/// count and line range, not a bare glyph + verb.
private struct MinifiedInstrumentLabel: View {
    let chip: ToolChip
    var level: CompactionLevel = .expanded

    var body: some View {
        Text(chip.minifiedSummary)
            .font(.system(size: level == .micro ? 9 : 10))
            .foregroundStyle(level == .micro ? .tertiary : .secondary)
            .lineLimit(level < .compact ? 2 : 1)
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

    /// Horologium status kinds that belong to a specific instrument invocation —
    /// they carry the same uuid as their `tool_starting` envelope and merge into
    /// that single chip instead of each spawning a new flow entry. Shared by
    /// Pythia's and Salomo's stream handlers.
    static let statusKinds: Set<String> = [
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

    /// Translate a Horologium status kind + data into a one-line live status
    /// (for the minified summary) and a richer detail line (for the expanded view).
    static func mergeText(kind: String, data: [String: Any]) -> (status: String?, detail: String?) {
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

    /// Collapse a Ruby-side `Scriptorium.html` message into plain text for the
    /// minimized line — strips `<file>`/`<a>`/`<strong>` tags and decodes the
    /// few entities Redcarpet escapes, preserving the human meaning (path,
    /// byte count, line range) without the markup.
    static func plainText(fromHTML html: String) -> String {
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
}

// MARK: - Instrumenta semantics

/// Hermetic glyph + label + tint per instrument domain, so a tool call reads as
/// *meaning* (what it does) rather than a debug param dump.
struct InstrumentaSemantics {
    let glyph: String
    let label: String
    let tint: Color
    /// True for the oracle's own meta-instruments (Aegis, conjuration,
    /// metempsychosis, communication, task orchestration) — the mind managing
    /// itself — rendered as a quiet system veil instead of a working-tool card.
    let system: Bool

    init(glyph: String, label: String, tint: Color, system: Bool = false) {
        self.glyph = glyph
        self.label = label
        self.tint = tint
        self.system = system
    }

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
            return InstrumentaSemantics(glyph: "🦋", label: "Wanderung", tint: .indigo, system: true)
        case "aegis":
            return InstrumentaSemantics(glyph: "🛡️", label: "Aegis", tint: .indigo, system: true)
        case "create_task", "execute_task", "update_task", "evaluate_task", "list_tasks", "remove_task":
            return InstrumentaSemantics(glyph: "⚗️", label: "Aufgabe", tint: .pink, system: true)
        case "oracle_conjuration":
            return InstrumentaSemantics(glyph: "🔮", label: "Beschwörung", tint: .indigo, system: true)
        case "take_screenshot":
            return InstrumentaSemantics(glyph: "👁️", label: "Blick", tint: .gray)
        case "tell_user", "ask_user":
            return InstrumentaSemantics(glyph: "🗣️", label: "Spricht", tint: .teal, system: true)
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
struct ToolChipRow: View {
    let chip: ToolChip
    var level: CompactionLevel = .expanded
    let isExpanded: Bool
    let onToggle: () -> Void
    private var sem: InstrumentaSemantics { InstrumentaSemantics.forTool(chip.name) }
    private var morphID: String { "chip-\(chip.id)" }
    @Namespace private var morph

    var body: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                expandedView
                    .matchedGeometryEffect(id: morphID, in: morph)
                    .transition(.opacity)
            } else {
                collapsedView
                    .matchedGeometryEffect(id: morphID, in: morph)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: isExpanded)
    }

    /// The instrument at rest — a minified one-liner. It does not linger beside
    /// the unfolded card: both states share one matched-geometry frame, so the
    /// capsule *grows* into the full card while the two contents crossfade.
    private var collapsedView: some View {
        Button {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                onToggle()
            }
        } label: {
            HStack(spacing: 5) {
                if level < .compact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                Text(chip.minifiedSummary)
                    .font(.system(size: level == .micro ? 9 : 10))
                    .foregroundStyle(level == .micro ? .tertiary : .primary)
                    .lineLimit(level < .compact ? 2 : 1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if chip.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(sem.tint)
                } else if level < .compact {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, level == .micro ? 2 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(sem.tint.opacity(chip.done ? 0.15 : 0.35), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The unfolded instrument. Only a whisper-thin collapse strip stays
    /// persistent; the card's own header becomes the sole voice of the state.
    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    onToggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("einklappen")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            chipBody
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var chipBody: some View {
        if chip.kind == .cli {
            CliChipView(chip: chip)
        } else if CompanionTool.isCompanion(chip.name) {
            CompanionChipView(chip: chip)
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
        } else if sem.system {
            SystemInstrumentChipView(chip: chip)
        } else {
            InstrumentChipView(chip: chip)
        }
    }
}

/// Aegis and the oracle's own meta-instruments (conjuration, metempsychosis,
/// communication, orchestration) — the mind managing itself, not the filesystem.
/// Rendered as a quiet system veil: a shield-styled header and the orientation
/// note, without the raw result dump a working tool would show.
private struct SystemInstrumentChipView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette
    private var sem: InstrumentaSemantics { InstrumentaSemantics.forTool(chip.name) }

    /// The most meaningful human line from the call's arguments (Aegis summary,
    /// a spoken message, a question, a conjuration prompt).
    private var note: String? {
        guard let data = chip.args.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["summary", "message", "question", "prompt"] {
            if let s = dict[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(sem.glyph)
                    .font(.system(size: 10))
                Text(sem.label)
                    .font(.system(size: 9, weight: .semibold))
                Text("SYSTEM")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(sem.tint.opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(sem.tint.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
                if chip.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(sem.tint)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if let note {
                Text(renderInline(note))
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let message = chip.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let status = chip.status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(sem.tint.opacity(0.9))
                    .lineLimit(2)
            }
            if let detail = chip.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [sem.tint.opacity(0.14), palette.complementaryColor.opacity(0.05), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(sem.tint.opacity(chip.done ? 0.18 : 0.40), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
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
/// The outer `ToolChipRow` already owns the minimize/expand toggle (its header
/// shows the command), so this body renders the result directly — no nested
/// chevron, no second collapsed layer swallowing the user's tap.
private struct CliChipView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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

            if !chip.output.isEmpty {
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
    /// The course itself — membership in it is derived, never duplicated here.
    @ObservedObject private var aegis = AegisWidgetModel.shared
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            CompanionFlowLayout(spacing: 7, maxItemWidth: 236) {
                ForEach(model.companionBubbles) { bubble in
                    CompanionSpeechBubble(
                        bubble: bubble,
                        conjoined: model.isConjoined(bubble),
                        palette: palette,
                        action: { model.conjoinBubble(bubble) },
                        reply: { model.quoteBubble(bubble) }
                    )
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
///
/// Two gestures: clicking the bubble body *acts* on the suggestion (the prompt
/// becomes the next turn); the tiny trailing reply button instead *opens it into
/// the prompt bar* as an editable quote and switches to that companion's voice.
private struct CompanionSpeechBubble: View {
    let bubble: CompanionBubble
    let conjoined: Bool
    let palette: PythiaPalette
    let action: () -> Void
    let reply: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Portrait — the companion's glyph, outside the bubble so the speech
            // visibly originates from the speaker rather than carrying its name
            // as part of the utterance.
            Text(bubble.glyph)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                // Name — above the bubble, in the accent color.
                if !bubble.name.isEmpty {
                    Text(bubble.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.accentColor)
                        .padding(.leading, 12)
                }

                ZStack(alignment: .bottomTrailing) {
                    Button(action: action) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bubble.prompt)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            // Reserve room so the trailing reply button never covers text.
                            Color.clear.frame(height: 16)
                        }
                        .padding(.horizontal, 11)
                        .padding(.top, 7)
                        .padding(.bottom, 8)
                        .frame(maxWidth: 236, alignment: .leading)
                        .background(.regularMaterial, in: LeftTailBubbleShape())
                        .overlay(
                            LeftTailBubbleShape()
                                .stroke(.white.opacity(hovered ? 0.24 : 0.11), lineWidth: 0.5)
                        )
                        .contentShape(LeftTailBubbleShape())
                    }
                    .buttonStyle(.plain)
                    .help(conjoined ? "Im Kurs" : "In den Kurs aufnehmen")
                    .overlay(alignment: .topTrailing) {
                        if conjoined {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.accentColor)
                                .padding(.top, 5)
                                .padding(.trailing, 7)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    // Tiny reply button — "an Prompt anhängen" (quote, keep the
                    // rest so several companions can be quoted together).
                    Button(action: reply) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.accentColor)
                            .frame(width: 22, height: 18)
                            .background(palette.accentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 11)
                    .padding(.bottom, 7)
                    .help("An Prompt anhängen")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaleEffect(hovered ? 1.02 : 1.0)
        .shadow(color: palette.shineColor.opacity(hovered ? 0.30 : 0.14), radius: hovered ? 7 : 4, y: 2)
        .animation(.easeInOut(duration: 0.16), value: hovered)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: conjoined)
        .onHover { hovered = $0 }
        .help(bubble.prompt)
    }
}

/// A rounded speech bubble whose tail points left toward the speaking
/// companion's glyph — the chat-flow counterpart of the suggestion bubble's
/// downward tail.
private struct LeftTailBubbleShape: Shape {
    var cornerRadius: CGFloat = 9
    var tailSize: CGSize = CGSize(width: 6, height: 8)
    var tailOffset: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let bubbleRect = CGRect(
            x: rect.minX + tailSize.width,
            y: rect.minY,
            width: rect.width - tailSize.width,
            height: rect.height
        )
        var path = Path()
        path.addRoundedRect(in: bubbleRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        let baseX = bubbleRect.minX
        let tipX = rect.minX
        let midY = rect.minY + tailOffset + tailSize.height * 0.5
        path.move(to: CGPoint(x: baseX, y: rect.minY + tailOffset))
        path.addLine(to: CGPoint(x: baseX, y: rect.minY + tailOffset + tailSize.height))
        path.addLine(to: CGPoint(x: tipX, y: midY))
        path.closeSubpath()
        return path
    }
}

/// The mirror of `LeftTailBubbleShape` — the tail points right, anchoring the
/// user's own voice to the trailing edge of the transcript.
private struct RightTailBubbleShape: Shape {
    var cornerRadius: CGFloat = 9
    var tailSize: CGSize = CGSize(width: 6, height: 8)
    var tailOffset: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let bubbleRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width - tailSize.width,
            height: rect.height
        )
        var path = Path()
        path.addRoundedRect(in: bubbleRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        let baseX = bubbleRect.maxX
        let tipX = rect.maxX
        let midY = rect.minY + tailOffset + tailSize.height * 0.5
        path.move(to: CGPoint(x: baseX, y: rect.minY + tailOffset))
        path.addLine(to: CGPoint(x: baseX, y: rect.minY + tailOffset + tailSize.height))
        path.addLine(to: CGPoint(x: tipX, y: midY))
        path.closeSubpath()
        return path
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

// MARK: - Ask-user dialog

/// The agent's `ask_user` instrument surfaces as a window-modal sheet — the
/// paused turn waits until the user answers (confirm / select / free-form). This
/// is the flexible UI replacement for repetitive companion tasks: the companion
/// acts (build, deploy, …) and consults here only when a decision is needed.
private struct AskUserDialog: View {
    let prompt: AskUserPrompt
    let onRespond: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pythiaPalette) private var palette
    @State private var text = ""

    private var isPrompt: Bool { prompt.type == "prompt" }
    private var isSelect: Bool { prompt.type == "select" }
    private var confirmLabels: [String] {
        prompt.options.count >= 2 ? [prompt.options[0], prompt.options[1]] : ["Yes", "No"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.accentColor)
                Text("Frage des Orakels")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(prompt.message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if isSelect {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(prompt.options, id: \.self) { option in
                            Button {
                                onRespond(option)
                                dismiss()
                            } label: {
                                Text(option)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(palette.accentColor.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if isPrompt {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 80)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if isPrompt {
                    Button("Abbrechen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Senden") {
                        onRespond(text)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if isSelect {
                    Button("Abbrechen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    HStack(spacing: 6) {
                        TextField("Eigene Antwort…", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit {
                                onRespond(text)
                                dismiss()
                            }
                        Button("Senden") {
                            onRespond(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button(confirmLabels[1]) {
                        onRespond(confirmLabels[1])
                        dismiss()
                    }
                    Spacer()
                    Button(confirmLabels[0]) {
                        onRespond(confirmLabels[0])
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Input bar

private struct InputBar: View {
    @ObservedObject var model: PythiaChatModel
    @FocusState private var inputFocused: Bool
    @Environment(\.pythiaPalette) private var palette

    /// `$` as the first character opens the polymorphic Pythia CLI: the same
    /// shell the agent's `run_command` tool inhabits. One interface, two hands.
    private var cliMode: Bool { model.draft.hasPrefix("$") }
    /// The companion spoken to directly (nil = Pythia's home voice).
    private var companion: Companion? {
        guard model.companionID != "pythia" else { return nil }
        return pythiaCompanions.first { $0.id == model.companionID }
    }
    private var placeholder: String {
        if model.heldTurn { return "⏸ gehalten — ⏎ webt deine Zeile in den laufenden Faden…" }
        if model.paused { return "⏸ gehalten — ▶ lässt den Kurs fliegen…" }
        if cliMode { return "command… (⇧⏎ neue Zeile)" }
        if let companion { return "Antworte \(companion.displayName)… (⇧⏎ neue Zeile)" }
        return "Ask… (⇧⏎ neue Zeile)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Portrait + name of the companion being spoken to directly.
            if let companion {
                HStack(spacing: 6) {
                    Text(companion.glyph)
                        .font(.system(size: 11))
                    Text(companion.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.accentColor)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .bottom, spacing: 8) {
                transportControls
                VStack(alignment: .leading, spacing: 4) {
                    if cliMode && !model.cliCwd.isEmpty {
                        Text(model.cliCwd)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.accentColor.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.accentColor.opacity(0.10), in: Capsule())
                            .frame(maxWidth: 220, alignment: .leading)
                            .help(model.cliCwd)
                    }
                    ZStack(alignment: .topLeading) {
                        TextField("", text: $model.draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .focused($inputFocused)
                            .lineLimit(1...6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .onKeyPress(.return) {
                                // ⇧⏎ inserts a newline; plain ⏎ sends.
                                if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                                submit()
                                return .handled
                            }
                        if model.draft.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
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
        .onChange(of: model.pendingPrompt) { _, newValue in
            guard let newValue else { return }
            model.draft = newValue
            model.pendingPrompt = nil
            inputFocused = true
        }
        .onAppear {
            if let prompt = model.pendingPrompt {
                model.draft = prompt
                model.pendingPrompt = nil
                inputFocused = true
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.companionID)
        .animation(.easeInOut(duration: 0.18), value: model.busy)
        .animation(.easeInOut(duration: 0.18), value: model.paused)
    }

    /// ⏸/▶ + ⏹ — Pythia's own transport, on the prompt box where the hand already
    /// is. The state belongs to the turn, never to the Ægis: a hold is a fact
    /// about a running chapter, not about the mind's orientation. Shown only when
    /// there is something to hold, release or tear.
    @ViewBuilder
    private var transportControls: some View {
        if model.busy || model.paused || model.pendingCount > 0 {
            HStack(spacing: 4) {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.paused ? palette.accentColor : .white)
                .glassEffect(.regular.interactive(), in: Circle())
                .help(model.paused
                      ? "▶ Weiterlaufen — der gefasste Kurs fliegt"
                      : "⏸ Anhalten — der Faden wartet an der nächsten Stufe")

                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .glassEffect(.regular.interactive(), in: Circle())
                .help("⏹ Faden abreißen — der Agent hält sofort an")
            }
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    private func submit() {
        let text = model.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.draft = ""
        if text.hasPrefix("$") {
            model.sendCli(text)
        } else {
            model.send(text)
        }
    }
}