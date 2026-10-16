import Foundation

// MARK: - Chat

/// One node in the conversation. Mirrors the Mac's `ChatMessage` shape so the
/// iOS companion stays in correspondence with PythiaPanel rather than drifting.
public struct ChatMessage: Identifiable, Equatable, Codable {
    public var id = UUID()
    public let role: String          // "user" | "assistant"
    public let text: String
    public let glyph: String
    /// The model's `reasoning_content` (thinking mode) — collapsed by default.
    public var reasoning: String? = nil
    /// Non-empty when a companion speaks through Pythia's turn; nil = Pythia's voice.
    public var speakerName: String? = nil
    /// The companion this turn was addressed to ("pythia" default) — lets the
    /// per-voice history be rebuilt after an edit/reload/delete truncates the stream.
    public var companionID: String? = nil

    public init(id: UUID = UUID(), role: String, text: String, glyph: String,
                reasoning: String? = nil, speakerName: String? = nil,
                companionID: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.glyph = glyph
        self.reasoning = reasoning
        self.speakerName = speakerName
        self.companionID = companionID
    }
}

// MARK: - Companion

public struct Companion: Identifiable, Equatable {
    public let id: String
    public let glyph: String
    public let label: String
    public var title: String
    public var trigger: String
    public var grant: String      // spy · scribe · executor
    public var reach: String      // "seer" carries the æther
    public var tools: [String]

    public var displayName: String { title.isEmpty ? label : title }

    public init(id: String, glyph: String, label: String, title: String = "",
                trigger: String = "", grant: String = "", reach: String = "",
                tools: [String] = []) {
        self.id = id
        self.glyph = glyph
        self.label = label
        self.title = title
        self.trigger = trigger
        self.grant = grant
        self.reach = reach
        self.tools = tools
    }
}

/// A transient one-click voice offered by the oracle after a turn.
public struct CompanionBubble: Identifiable, Equatable {
    public let id = UUID()
    public let glyph: String
    public let name: String
    public let prompt: String

    public init(glyph: String, name: String, prompt: String) {
        self.glyph = glyph
        self.name = name
        self.prompt = prompt
    }
}

// MARK: - Wire

/// `/aether/heartbeat` response — a running AetherCodex context.
public struct PeerContext: Identifiable, Hashable {
    public var id: String { "\(host):\(port)" }
    public let name: String
    public let host: String
    public let port: Int
    public let path: String?
    public let version: String?
    public let capabilities: [String]
    public let busy: Bool
    public let activeTaskCount: Int

    public init(name: String, host: String, port: Int, path: String?,
                version: String?, capabilities: [String], busy: Bool, activeTaskCount: Int) {
        self.name = name
        self.host = host
        self.port = port
        self.path = path
        self.version = version
        self.capabilities = capabilities
        self.busy = busy
        self.activeTaskCount = activeTaskCount
    }
}

/// `POST /aether/invoke` (type == "chat") response.
public struct OracleAnswer: Codable {
    public let answer: String
    public let html: String?
    public let sourceContext: String?

    public init(answer: String, html: String?, sourceContext: String?) {
        self.answer = answer
        self.html = html
        self.sourceContext = sourceContext
    }
}

/// `GET /aether/voices` entry — the Vox roster.
public struct Voice: Identifiable, Equatable, Codable {
    public var id: String { name }
    public let name: String
    public let locale: String
    public let language: String

    public init(name: String, locale: String, language: String) {
        self.name = name
        self.locale = locale
        self.language = language
    }
}

/// `GET /aether/aegis` — the current reasoning state.
public struct AegisState: Codable {
    public var thinking: String
    public var temperature: Double
    public var workingDir: String?
    public var summary: String
    public var tags: [String]

    public init(thinking: String, temperature: Double, workingDir: String?,
                summary: String, tags: [String]) {
        self.thinking = thinking
        self.temperature = temperature
        self.workingDir = workingDir
        self.summary = summary
        self.tags = tags
    }
}