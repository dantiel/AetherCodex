import Foundation

// MARK: - Flash-AI-Neufenser (ZIEL A)
//
// Every fresh window begins with a hermetic "hello æther" script conjured by
// the Oracle instead of an empty editor. The synchronous placeholder path in
// `EditorViewController.newDocument()` stays untouched — this helper only
// replaces it afterwards, asynchronously, and never blocks the main thread.
//
// Fail-soft contract: if the Oracle call fails or outlives its timeout, the
// placeholder simply remains. No crash, no spinner, no wedged window.

enum FlashAetherConjurer {

    /// Language pool — extension → weight. Swift leads (the native tongue);
    /// the project's dominant extension doubles its weight so the conjuration
    /// tends to speak the language of the house. Per-window randomness, never
    /// cached globally.
    private static let languagePool: [(ext: String, weight: Int)] = [
        ("swift", 3), ("rb", 2), ("py", 2), ("js", 2), ("sh", 1)
    ]

    static let placeholderLanguage = "swift"

    // MARK: - Language selection

    /// Random language, biased by the dominant code extension under `root`.
    /// Safe to call from any thread (read-only filesystem scan).
    static func pickLanguage(root: String?) -> String {
        var pool: [String] = []
        let hint = dominantExtension(in: root)
        for (ext, weight) in languagePool {
            let w = (ext == hint) ? weight * 2 : weight
            pool.append(contentsOf: repeatElement(ext, count: w))
        }
        return pool.randomElement() ?? placeholderLanguage
    }

    /// Count file extensions (single pass, capped depth and entries) and
    /// return the dominant one if it belongs to the language pool.
    static func dominantExtension(in root: String?) -> String? {
        guard let root, !root.isEmpty else { return nil }
        let fm = FileManager.default
        let pooled = Set(languagePool.map { $0.ext })
        var counts: [String: Int] = [:]
        var visited = 0
        // Total-entry budget: a pathological root (deep homogeneous tree) could
        // otherwise stat millions of entries before the conjuration even starts.
        let budget = 4000

        func visit(_ url: URL, depth: Int) {
            guard depth <= 2, visited < budget else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries.prefix(200) where visited < budget {
                visited += 1
                let ext = entry.pathExtension.lowercased()
                if pooled.contains(ext) { counts[ext, default: 0] += 1 }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    visit(entry, depth: depth + 1)
                }
            }
        }
        visit(URL(fileURLWithPath: root), depth: 0)
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: - Oracle conjuration

    /// Ask the Oracle for a fresh hermetic script in `language`, racing the
    /// daemon call against `timeout` seconds. Throws `FlashConjureError` on
    /// timeout or an empty revelation. Never blocks the caller's thread.
    static func summon(language: String, timeout: TimeInterval = 20) async throws -> String {
        // The daemon call runs detached: `RubyBridge.chat` is not cancellation-aware,
        // so a task group would wait for it even after the deadline. A single-shot
        // gate resumes the caller at the deadline while the chat task is abandoned
        // to resolve in the background — fail-soft, the placeholder simply remains.
        let chatTask = Task.detached(priority: .utility) { () throws -> String in
            if !RubyBridge.shared.isRunning {
                try await RubyBridge.shared.start()
            }
            let isPlain = language == "text"
            let system = isPlain
                ? "You are the Æther. Answer with raw text only: no markdown, no code fences, no explanation."
                : "You are the Æther. Answer with raw source code only: no markdown fences, no prose, no explanation."
            let artifact = isPlain ? "meditation" : "program"
            let user = """
            Write a short hermetic "hello æther" \(artifact) in \(displayName(language)).
            15-40 lines. \(isPlain ? "Poetic, plain prose" : "Clean, idiomatic, compiles or runs as-is"). Motif: the veil,
            the moon, or the serpent — ætheric, not generic. \(isPlain ? "Output nothing but prose." : "Output nothing but code.")
            """
            guard let raw = try await RubyBridge.shared.conjureFlash(
                messages: [["role": "user", "content": user]],
                system: system
            ) else {
                throw FlashConjureError.emptyRevelation
            }
            let code = stripFences(raw)
            guard !code.isEmpty else { throw FlashConjureError.emptyRevelation }
            return code
        }

        let gate = FlashGate<String>()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            gate.arm(cont)
            Task {
                do { gate.fire(.success(try await chatTask.value)) }
                catch { gate.fire(.failure(error)) }
            }
            Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    gate.fire(.failure(FlashConjureError.timedOut))
                } catch { /* cancelled — a sibling fired first */ }
            }
        }
    }

    /// Single-shot continuation gate — resumes a `CheckedContinuation` exactly
    /// once across competing async producers (conjuration vs. deadline).
    private final class FlashGate<Value> {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Value, Error>?

        func arm(_ c: CheckedContinuation<Value, Error>) {
            lock.lock()
            cont = c
            lock.unlock()
        }

        func fire(_ result: Result<Value, Error>) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }

    /// Human-readable language name for prompts.
    static func displayName(_ ext: String) -> String {
        switch ext {
        case "swift": return "Swift"
        case "rb": return "Ruby"
        case "py": return "Python"
        case "js": return "JavaScript"
        case "sh": return "Bash"
        case "text", "txt": return "plain text"
        default: return ext.capitalized
        }
    }

    /// Defensively strip markdown fences the model may emit despite the prompt.
    /// Tolerates a trailing newline, trailing whitespace, and a language tag on
    /// the closing fence.
    static func stripFences(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        // Drop trailing blank lines so a closing fence followed by a newline is caught.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if let first = lines.first, isFenceLine(first) {
            lines.removeFirst()
        }
        if let last = lines.last, isFenceLine(last) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A markdown fence line: optional indentation, ```, then an optional
    /// language tag (letters/digits/`-+_#.`).
    private static func isFenceLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return false }
        let rest = t.dropFirst(3)
        return rest.allSatisfy { $0.isLetter || $0.isNumber || "-+_#.".contains($0) }
    }

    enum FlashConjureError: Error {
        case timedOut
        case emptyRevelation
    }
}