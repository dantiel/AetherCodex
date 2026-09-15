import Foundation
import Darwin

// MARK: - Ruby Bridge Error Types

enum RubyBridgeError: Error, LocalizedError {
    case processLaunchFailed(String)
    case communicationError(String)
    case timeoutError
    case invalidResponse(String)
    case rubyError(String)

    /// Human-readable cause — surfaces real diagnostics instead of the opaque
    /// NSError fallback ("The operation couldn't be completed. (… error 0.)").
    var errorDescription: String? {
        switch self {
        case .processLaunchFailed(let message):
            return "Failed to launch Ruby daemon: \(message)"
        case .communicationError(let message):
            return "Ruby daemon communication error: \(message)"
        case .timeoutError:
            return "Ruby daemon request timed out"
        case .invalidResponse(let message):
            return "Invalid Ruby daemon response: \(message)"
        case .rubyError(let message):
            return "Ruby error: \(message)"
        }
    }
}

// MARK: - Ruby Bridge Response

/// Parsed frame from the daemon. `result` can be a string, array, or object,
/// so we capture all three shapes and expose the matching one.
struct RubyBridgeResponse {
    let success: Bool
    let resultString: String?
    let resultArray: [[String: Any]]?
    let resultDict: [String: Any]?
    let error: String?

    init(from json: [String: Any]) {
        self.success = json["success"] as? Bool ?? false
        self.error = json["error"] as? String

        if let result = json["result"] {
            if let s = result as? String {
                self.resultString = s
                self.resultArray = nil
                self.resultDict = nil
            } else if let a = result as? [[String: Any]] {
                self.resultString = nil
                self.resultArray = a
                self.resultDict = nil
            } else if let d = result as? [String: Any] {
                self.resultString = nil
                self.resultArray = nil
                self.resultDict = d
            } else {
                self.resultString = "\(result)"
                self.resultArray = nil
                self.resultDict = nil
            }
        } else {
            self.resultString = nil
            self.resultArray = nil
            self.resultDict = nil
        }
    }
}

// MARK: - Daemon Events

/// A companion voice shipped in the daemon's `ready` frame — the roster that
/// lets Swift render the same pantheon the Ruby side speaks with.
struct CompanionInfo {
    let key: String
    let glyph: String
    let name: String
    let temperature: Double?
    let thinking: String?
}

/// Non-request frames the daemon emits outside the request/response cycle.
enum DaemonEvent {
    /// A torn thread offer: the daemon's worker died or timed out mid-turn and
    /// asks whether to re-weave the last intent. `RecoverSuggestion` carries
    /// the glyph/prompt/action plus the salvaged Aegis summary.
    case recoverSuggestion(RecoverSuggestion)
    /// Any frame type Swift doesn't explicitly route (forwarded for future use).
    case other(type: String, json: [String: Any])
}

/// Structured recover offer emitted by the daemon when a turn breaks.
struct RecoverSuggestion {
    let requestId: Int?
    let glyph: String
    let prompt: String
    let action: String
    let lastIntent: String?
}

// MARK: - Ruby Bridge

/// Swift-to-Ruby communication bridge using a framed JSON protocol over pipes.
///
/// The daemon (`Ruby/standalone_daemon.rb`) emits newline-delimited frames:
///   - `{"type":"ready", ...}`                       at startup
///   - `{"type":"stream","method":...,"payload":...}` during execution
///   - `{"type":"result","request_id":N,...,"result":...}` per command
///
/// A background reader dispatches frames; `send` awaits the matching result
/// while streaming frames are forwarded to `onStream`.
class RubyBridge: ObservableObject {
    static let shared = RubyBridge()

    /// Posted after the daemon is killed and reset following a wedged/timed-out
    /// turn, so the UI can surface a reconnect notice before the next request
    /// relaunches a fresh daemon.
    static let didRecoverNotification = Notification.Name("RubyBridge.didRecover")

    /// Published so the Æther Debug window can breathe with the daemon
    /// (status dot, restart affordance) without polling.
    @Published private(set) var isRunning = false
    private var startInFlight = false
    var lastError: String?

    /// Streaming callback — invoked on the reader queue with (method, payload).
    var onStream: ((String?, [String: Any]?) -> Void)?

    /// Event callback for non-request frames (`recover_suggestion`, …) —
    /// dispatched on the reader queue. The Riss macro travels through here.
    var onEvent: ((DaemonEvent) -> Void)?

    /// Companion roster parsed from the daemon's `ready` frame — the pantheon
    /// as the Ruby side knows it, so Swift never hardcodes a divergent copy.
    @Published private(set) var companionRoster: [CompanionInfo] = []

    /// The Ruby brain's stderr (debug `puts`), drained continuously so the pipe
    /// can never fill and wedge the daemon. Capped ring buffer — the debug log
    /// window reads from here. Wire protocol stays on stdout, pure and framed.
    @Published private(set) var daemonLog: [String] = []

    private var process: Process?
    private var inputPipe: FileHandle?
    private var outputPipe: FileHandle?
    private var errorPipe: FileHandle?

    private var readerBuffer = Data()
    private var errorBuffer = Data()
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private let maxDaemonLogLines = 2000

    private var nextRequestId = 0
    /// In-flight requests keyed by `request_id`. Matching by id (instead of a single
    /// slot) prevents a late result from a timed-out turn being misdelivered to the
    /// next request — the original cause of the "timeout then dead" wedge.
    private var pendingContinuations: [Int: CheckedContinuation<RubyBridgeResponse, Error>] = [:]
    private var startupContinuation: CheckedContinuation<Void, Error>?

    /// Serializes writes to the daemon's stdin pipe so the timeout interrupt frame
    /// (fired from a Task) can never tear a frame written by `send`.
    private let writeLock = NSLock()

    /// Guards `pendingContinuations` (mutated from the reader Task, the timeout Task,
    /// and `resumePendingWithError`). `removeValue` under the lock also guarantees a
    /// continuation is resumed exactly once — never double-resumed, never leaked.
    private let pendingLock = NSLock()

    private let rubyPath: String = {
        let possiblePaths = [
            "/Users/d/.rvm/rubies/ruby-3.1.7/bin/ruby",  // RVM Ruby (preferred)
            "/usr/local/bin/ruby",                       // Homebrew
            "/usr/bin/ruby"                              // System (fallback)
        ]
        for path in possiblePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/ruby"
    }()

    private let daemonScript: String
    private let requestTimeout: TimeInterval = 600.0

    private init() {
        let resourcesPath = Bundle.main.resourcePath ?? Bundle.main.bundlePath
        daemonScript = "\(resourcesPath)/Ruby/standalone_daemon.rb"
    }

    /// Project root passed to the daemon (resolves .aethercodex + data dirs).
    var projectRoot: String {
        if let env = ProcessInfo.processInfo.environment["AETHER_PROJECT_ROOT"], !env.isEmpty {
            return env
        }
        // The .app bundle lives at the project root in development.
        return Bundle.main.bundleURL.deletingLastPathComponent().path
    }

    // MARK: - Process Lifecycle

    func initialize() {
        // Lazy — daemon starts on first use.
    }

    func cleanup() {
        stop()
    }

    /// Stop and start the daemon in one breath (Æther Debug window "Restart").
    func restart() async throws {
        stop()
        try await start()
    }

    /// Reset the debug log ring buffer (Æther Debug window "Clear").
    func clearDaemonLog() {
        daemonLog = []
    }

    /// Start the Ruby daemon and wait for its ready frame.
    func start() async throws {
        guard !isRunning, !startInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }

        guard FileManager.default.fileExists(atPath: daemonScript) else {
            throw RubyBridgeError.processLaunchFailed("Ruby daemon script not found at: \(daemonScript)")
        }
        guard FileManager.default.isExecutableFile(atPath: rubyPath) else {
            throw RubyBridgeError.processLaunchFailed("Ruby not executable at: \(rubyPath)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rubyPath)
        proc.arguments = [daemonScript]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        env["AETHER_RUBY_PATH"] = (Bundle.main.resourcePath ?? Bundle.main.bundlePath) + "/Ruby"
        env["BUNDLE_GEMFILE"] = URL(fileURLWithPath: daemonScript).deletingLastPathComponent().appendingPathComponent("Gemfile").path
        env["AETHER_DAEMON"] = "1"
        env["AETHER_PROJECT_ROOT"] = projectRoot
        proc.environment = env

        process = proc
        inputPipe = stdinPipe.fileHandleForWriting
        outputPipe = stdoutPipe.fileHandleForReading
        errorPipe = stderrPipe.fileHandleForReading
        readerBuffer = Data()
        nextRequestId = 0
        pendingContinuations = [:]
        startupContinuation = nil

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.resumePendingWithError(RubyBridgeError.communicationError("Ruby daemon exited"))
            }
        }

        do {
            try proc.run()
        } catch {
            throw RubyBridgeError.processLaunchFailed("Failed to launch: \(error.localizedDescription)")
        }

        isRunning = true
        startReader()
        startErrorReader()

        // Await the ready frame (with a generous startup timeout).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            startupContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.startupContinuation != nil else { return }
                self.startupContinuation = nil
                cont.resume(throwing: RubyBridgeError.processLaunchFailed("Timed out waiting for daemon ready"))
            }
        }
    }

    func stop() {
        let proc = process
        let pid = proc?.processIdentifier
        proc?.terminationHandler = nil
        proc?.terminate()

        // SIGTERM hits the daemon's `trap('TERM') { exit }` → clean shutdown. If a
        // native call (network) is wedged and cannot unwind, escalate to SIGKILL so a
        // restart never resurrects a zombie. `kill(pid, 0)` is a pure liveness probe.
        if let pid, pid > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if kill(pid, 0) == 0 {
                    _ = kill(pid, SIGKILL)
                    NSLog("[RubyBridge] SIGKILL sent to wedged daemon pid \(pid)")
                }
            }
        }

        process = nil
        lineContinuation?.finish()
        lineContinuation = nil
        readerTask?.cancel()
        readerTask = nil
        errorReaderTask?.cancel()
        errorReaderTask = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false
        resumePendingWithError(RubyBridgeError.communicationError("Daemon stopped"))
    }

    // MARK: - Communication

    /// Send a command and await its result frame.
    @discardableResult
    func send(command: String, arguments: [String: Any] = [:]) async throws -> RubyBridgeResponse {
        guard isRunning, let inputPipe else {
            throw RubyBridgeError.communicationError("Ruby daemon not running")
        }

        let requestId = allocateRequestId()

        let request: [String: Any] = [
            "command": command,
            "arguments": arguments,
            "request_id": requestId
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              var requestString = String(data: requestData, encoding: .utf8) else {
            throw RubyBridgeError.communicationError("Failed to serialize request")
        }
        requestString += "\n"

        guard let inputData = requestString.data(using: .utf8) else {
            throw RubyBridgeError.communicationError("Failed to encode request")
        }

        let response: RubyBridgeResponse = try await withCheckedThrowingContinuation { continuation in
            pendingLock.lock()
            pendingContinuations[requestId] = continuation
            pendingLock.unlock()

            writeLock.lock()
            inputPipe.write(inputData)
            writeLock.unlock()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                guard let self else { return }
                self.pendingLock.lock()
                let abandoned = self.pendingContinuations.removeValue(forKey: requestId) != nil
                self.pendingLock.unlock()
                guard abandoned else { return }
                // Cooperative interrupt first — a merely-slow turn can still unwind
                // cleanly at its next loop boundary.
                self.sendInterrupt()
                // Hard-recover: a wedged worker (blocking network call) would starve
                // every later turn queued behind it. Killing the daemon lets the next
                // `start()` relaunch a fresh one instead of hanging forever.
                self.stop()
                // The daemon died before it could emit its own recover frame —
                // synthesize the torn-thread offer here so the Riss macro also
                // covers Swift-side lease expiry, not only Ruby-side errors.
                self.onEvent?(.recoverSuggestion(RecoverSuggestion(
                    requestId: requestId,
                    glyph: "🔥",
                    prompt: "Der Faden riss im Æther — letzte Absicht neu ansetzen?",
                    action: "recover_last_intent",
                    lastIntent: nil
                )))
                continuation.resume(throwing: RubyBridgeError.timeoutError)
                NotificationCenter.default.post(name: Self.didRecoverNotification, object: nil)
            }
        }

        return response
    }

    /// Allocate a unique request id under `pendingLock` so concurrent senders (a
    /// new turn + a timeout interrupt) can never race into a duplicate id. A
    /// duplicate id would cross-deliver the interrupt's result frame to a new
    /// turn's continuation — answering the wrong request and hanging the real one.
    private func allocateRequestId() -> Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        nextRequestId += 1
        return nextRequestId
    }

    /// Fire-and-forget interrupt. The daemon routes `interrupt` inline on its main
    /// thread (it's a control command), so this unjams the FIFO worker even while a
    /// heavy turn runs. Its result frame is dropped — no pending entry exists for it.
    private func sendInterrupt() {
        guard isRunning, let inputPipe else { return }
        let interruptId = allocateRequestId()
        let request: [String: Any] = [
            "command": "interrupt",
            "arguments": [:],
            "request_id": interruptId
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              var requestString = String(data: requestData, encoding: .utf8) else { return }
        requestString += "\n"
        guard let inputData = requestString.data(using: .utf8) else { return }
        writeLock.lock()
        inputPipe.write(inputData)
        writeLock.unlock()
    }

    /// Fail every in-flight request (daemon exit / stop). A timed-out request's id
    /// was already removed from the map, so its late result frame finds no entry and
    /// is silently dropped by `handleLine` — no cross-request misdelivery.
    private func resumePendingWithError(_ error: RubyBridgeError) {
        let startup = startupContinuation
        startupContinuation = nil
        startup?.resume(throwing: error)

        pendingLock.lock()
        let pendings = pendingContinuations
        pendingContinuations = [:]
        pendingLock.unlock()
        for pending in pendings.values {
            pending.resume(throwing: error)
        }
    }

    // MARK: - Reader

    private func startReader() {
        guard let outputPipe else { return }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        lineContinuation = continuation

        outputPipe.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.lineContinuation?.finish()
                return
            }
            self.readerBuffer.append(data)
            while let nl = self.readerBuffer.firstIndex(of: 0x0A) {
                let lineData = self.readerBuffer[..<nl]
                self.readerBuffer.removeSubrange(...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    self.lineContinuation?.yield(line)
                }
            }
        }

        readerTask = Task { [weak self] in
            for await line in stream {
                self?.handleLine(line)
            }
        }
    }

    /// Drain the daemon's stderr (debug `puts`) so the pipe never fills and wedges
    /// the brain. Lines are appended to `daemonLog` for the debug log window.
    private func startErrorReader() {
        guard let errorPipe else { return }

        errorPipe.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.errorBuffer.append(data)
            while let nl = self.errorBuffer.firstIndex(of: 0x0A) {
                let lineData = self.errorBuffer[..<nl]
                self.errorBuffer.removeSubrange(...nl)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DispatchQueue.main.async {
                        var log = self.daemonLog
                        log.append(line)
                        if log.count > self.maxDaemonLogLines {
                            log.removeFirst(log.count - self.maxDaemonLogLines)
                        }
                        self.daemonLog = log
                    }
                }
            }
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "ready":
            if let roster = json["companions"] as? [[String: Any]] {
                let parsed: [CompanionInfo] = roster.compactMap { entry in
                    guard let key = entry["key"] as? String else { return nil }
                    return CompanionInfo(
                        key: key,
                        glyph: entry["glyph"] as? String ?? "✦",
                        name: entry["name"] as? String ?? key,
                        temperature: entry["temperature"] as? Double,
                        thinking: entry["thinking"] as? String
                    )
                }
                // handleLine runs on the reader task, off the main actor —
                // CompanionPicker observes companionRoster on the main thread.
                // Publication must hop or SwiftUI rejects the background
                // objectWillChange emission.
                Task { @MainActor [weak self] in
                    self?.companionRoster = parsed
                }
            }
            let cont = startupContinuation
            startupContinuation = nil
            cont?.resume(returning: ())

        case "stream":
            let method = json["method"] as? String
            let payload = json["payload"] as? [String: Any]
            onStream?(method, payload)

        case "result":
            let response = RubyBridgeResponse(from: json)
            if let requestId = json["request_id"] as? Int {
                pendingLock.lock()
                let cont = pendingContinuations.removeValue(forKey: requestId)
                pendingLock.unlock()
                cont?.resume(returning: response)
            }
            // Late frames for abandoned/timed-out request_ids fall through here.

        case "recover_suggestion":
            onEvent?(.recoverSuggestion(RecoverSuggestion(
                requestId: json["request_id"] as? Int,
                glyph: json["glyph"] as? String ?? "🦊",
                prompt: json["prompt"] as? String ?? "Hier riss der Faden — weiterweben?",
                action: json["action"] as? String ?? "recover_last_intent",
                lastIntent: json["last_intent"] as? String
            )))

        default:
            onEvent?(.other(type: type, json: json))
        }
    }

    // MARK: - High-Level Commands

    /// Remember a note in Mnemosyne. Returns a dict with the new note id.
    func remember(content: String, tags: [String] = [], links: [String] = []) async throws -> [String: Any]? {
        let response = try await send(command: "remember", arguments: [
            "content": content,
            "tags": tags,
            "links": links
        ])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }

        // The daemon returns the integer note id.
        if let dict = response.resultDict { return dict }
        if let s = response.resultString, let id = Int(s) { return ["id": id] }
        return nil
    }

    /// Recall notes from Mnemosyne.
    func recallNotes(query: String, limit: Int = 5, tags: [String] = []) async throws -> [[String: Any]] {
        let response = try await send(command: "recall", arguments: [
            "query": query,
            "limit": limit,
            "tags": tags
        ])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultArray ?? []
    }

    /// Fetch the persisted conversation history (Chronicle entries) so a
    /// relaunched editor can resume the previous session's thread. Each entry
    /// carries a user `prompt` and assistant `answer`, mapped to OpenAI-style
    /// role/content messages.
    func fetchHistory(limit: Int = 20) async throws -> [[String: String]] {
        let response = try await send(command: "history", arguments: [
            "limit": limit,
            "include_tool_calls": false
        ])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        guard let entries = response.resultArray else { return [] }

        var messages: [[String: String]] = []
        for entry in entries {
            if let prompt = entry["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(["role": "user", "content": prompt])
            }
            if let answer = entry["answer"] as? String, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(["role": "assistant", "content": answer])
            }
        }
        return messages
    }

    /// Send a message to the Oracle (AI). Returns the plain-text answer.
    func oracle(message: String, context: [String: String] = [:]) async throws -> String? {
        var args: [String: Any] = ["message": message, "history": false]
        if !context.isEmpty { args["context"] = context }
        let response = try await send(command: "oracle", arguments: args)
        return try extractAnswer(from: response)
    }

    /// Multi-turn chat with the Oracle (Pythia persona by default).
    func chat(messages: [[String: String]], system: String? = nil, model: String? = nil) async throws -> String? {
        let reply = try await chatDetailed(messages: messages, system: system, model: model)
        return reply.text
    }

    /// Multi-turn chat that also surfaces the model's `reasoning_content`, so
    /// the Swift history can pass it back on the next turn (DeepSeek's thinking
    /// mode requires the field to round-trip).
    func chatDetailed(messages: [[String: String]], system: String? = nil, model: String? = nil, activeCompanions: [String] = []) async throws -> OracleReply {
        var args: [String: Any] = ["messages": messages, "history": false]
        if let system { args["system"] = system }
        if let model { args["model"] = model }
        if !activeCompanions.isEmpty { args["active_companions"] = activeCompanions }
        let response = try await send(command: "oracle", arguments: args)
        return try extractReply(from: response)
    }

    /// Ask a companion (Owl, Kitsune, etc.).
    func askCompanion(name: String, question: String) async throws -> String? {
        let response = try await send(command: "companion", arguments: [
            "name": name,
            "message": question,
            "history": false
        ])
        return try extractAnswer(from: response)
    }

    /// Get the current Aegis state.
    func getAegis() async throws -> [String: Any]? {
        let response = try await send(command: "aegis", arguments: ["action": "get"])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    /// Activate a project context by path. The daemon walks up to the nearest
    /// `.aethercodex`, re-points its working directory, memory db and config, and
    /// returns the resolved identity `{ project_root, name, config_path, memory_db }`.
    /// This makes the whole window polymorphic: opening any file/folder inherits
    /// the project context — "ICH bin der ÆTHER".
    @discardableResult
    func activateContext(path: String) async throws -> [String: Any]? {
        let response = try await send(command: "activate_context", arguments: ["path": path])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    /// Best-effort interrupt of the in-flight Oracle computation. The daemon
    /// sets the worker's cooperative pause flag; the next queued turn continues
    /// normally.
    @discardableResult
    func interrupt() async throws -> [String: Any]? {
        let response = try await send(command: "interrupt", arguments: [:])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    /// Execute a shell command through the polymorphic Pythia CLI. Returns the
    /// shared shell state `{ cwd, stdout, stderr, exit_status, ok }`.
    func cli(command: String, timeout: Int = 30) async throws -> [String: Any]? {
        let response = try await send(command: "cli", arguments: [
            "cmd": command,
            "timeout": timeout
        ])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }
   
    /// Fetch the polymorphic shell's current working directory (the daemon's
    /// merged ShellSession cwd) to seed the status line. `ping` is a control
    /// command, so it returns immediately even mid-computation.
    func fetchCwd() async throws -> String? {
        let response = try await send(command: "ping", arguments: [:])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict?["cwd"] as? String
    }

    /// Update the Aegis context. Returns a confirmation string.
    func updateAegis(summary: String, tags: [String] = []) async throws -> String? {
        let response = try await send(command: "aegis", arguments: [
            "action": "update",
            "summary": summary,
            "tags": tags
        ])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        if let dict = response.resultDict, dict["ok"] as? Bool == true { return "ok" }
        return response.resultString
    }

    // MARK: - Task engine

    func createTask(title: String, plan: String, workflowType: String = "full") async throws -> [String: Any]? {
        let response = try await send(command: "create_task", arguments: [
            "title": title, "plan": plan, "workflow_type": workflowType
        ])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    func executeTask(id: Int) async throws -> [String: Any]? {
        let response = try await send(command: "execute_task", arguments: ["id": id])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    func evaluateTask(id: Int) async throws -> [String: Any]? {
        let response = try await send(command: "evaluate_task", arguments: ["id": id])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    func listTasks() async throws -> [[String: Any]] {
        let response = try await send(command: "list_tasks", arguments: [:])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultArray ?? []
    }

    func removeTask(id: Int) async throws -> [String: Any]? {
        let response = try await send(command: "remove_task", arguments: ["id": id])
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        return response.resultDict
    }

    // MARK: - Helpers

    /// Extract the answer + reasoning_content from an Oracle result frame
    /// (`result.response.answer` / `result.response.reasoning_content`).
    private func extractReply(from response: RubyBridgeResponse) throws -> OracleReply {
        if let error = response.error { throw RubyBridgeError.rubyError(error) }
        if let dict = response.resultDict,
           let resp = dict["response"] as? [String: Any],
           let answer = resp["answer"] as? String {
            let reasoning = resp["reasoning_content"] as? String
            let suggestions = resp["companion_suggestions"] as? [[String: Any]] ?? []
            let says = Self.companionSays(from: resp["logs"] as? [[String: Any]] ?? [])
            return OracleReply(text: answer, reasoningContent: reasoning, companionSuggestions: suggestions, companionSays: says)
        }
        // Cooperative interrupt: the worker returned a divine-interrupt array.
        if let arr = response.resultArray,
           let first = arr.first,
           first["__divine_interrupt"] != nil {
            return OracleReply(text: "🛑 (paused)", reasoningContent: nil)
        }
        return OracleReply(text: response.resultString, reasoningContent: nil)
    }

    /// Extract the plain-text answer from an Oracle result frame
    /// (`result.response.answer`).
    private func extractAnswer(from response: RubyBridgeResponse) throws -> String? {
        try extractReply(from: response).text
    }

    /// Companion `_say`/`_ask` voices collected from the reply's `logs` — the
    /// active pantheon answering through default Pythia's turn.
    private static func companionSays(from logs: [[String: Any]]) -> [CompanionSay] {
        logs.compactMap { log in
            guard (log["type"] as? String) == "say",
                  let data = log["data"] as? [String: Any],
                  let message = data["message"] as? String,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CompanionSay(
                glyph: log["glyph"] as? String ?? "✦",
                name: log["companion"] as? String ?? "",
                message: message
            )
        }
    }
}

/// A decoded Oracle turn: the visible answer plus the model's private reasoning
/// (round-tripped on multi-turn so DeepSeek's thinking mode stays satisfied),
/// plus companion voices the Ruby side extracted from the reply.
/// A companion voice surfaced into the chat flow via its `_say`/`_ask` instrument —
/// the pantheon answering through default Pythia's turn.
struct CompanionSay {
    let glyph: String
    let name: String
    let message: String
}

/// A decoded Oracle turn: the visible answer plus the model's private reasoning
/// (round-tripped on multi-turn so DeepSeek's thinking mode stays satisfied),
/// plus companion voices the Ruby side extracted from the reply.
struct OracleReply {
    let text: String?
    let reasoningContent: String?
    let companionSuggestions: [[String: Any]]
    let companionSays: [CompanionSay]

    init(text: String?, reasoningContent: String?, companionSuggestions: [[String: Any]] = [], companionSays: [CompanionSay] = []) {
        self.text = text
        self.reasoningContent = reasoningContent
        self.companionSuggestions = companionSuggestions
        self.companionSays = companionSays
    }
}