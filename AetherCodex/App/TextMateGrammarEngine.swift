import Cocoa

// MARK: - TextMate Scope → TokenScope Mapper

/// Maps a full TextMate scope name (e.g. `entity.name.function.ruby`) to the
/// nearest `TokenScope` by longest-prefix match against every raw value. TextMate
/// appends language-specific suffixes (`.ruby`, `.yaml`) and finer dots
/// (`keyword.control.def`) — prefix matching folds them into the canonical scope
/// the theme already knows how to colour.
enum TextMateScopeMapper {

    /// Raw values sorted longest-first so the most specific scope wins.
    private static let scopesByLength: [(raw: String, scope: TokenScope)] = {
        TokenScope.allCases
            .map { (raw: $0.rawValue, scope: $0) }
            .sorted { $0.raw.count > $1.raw.count }
    }()

    static func map(_ scopeName: String) -> TokenScope {
        for (raw, scope) in scopesByLength {
            if scopeName == raw || scopeName.hasPrefix(raw + ".") {
                return scope
            }
        }
        return .plain
    }
}

// MARK: - TextMate Grammar Engine

/// Breadth syntax engine — highlights "almost all languages" by driving the
/// Ruby daemon's `textpow` interpreter (a full TextMate grammar engine backed by
/// Onigmo). Tokenization is synchronous: it round-trips the shared daemon on the
/// control path (fast, never queued behind heavy agentic turns) and caches the
/// result so repeated SwiftUI renders don't re-pay the IPC cost.
final class TextMateGrammarEngine {

    static let shared = TextMateGrammarEngine()

    /// LRU-ish token cache keyed by `scopeName + "\n" + text`.
    private var cache: [String: [Token]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 128
    private let cacheLock = NSLock()

    /// Registered extensions → scopeName (from `textmate_languages.yml`).
    private let registry: [String: String] = SyntaxLoader.loadTextmateRegistry()

    /// Whether the engine knows a grammar for this language id/extension.
    func supports(language: String) -> Bool {
        scopeName(for: language) != nil
    }

    func scopeName(for language: String) -> String? {
        let key = language.lowercased()
        if let scope = registry[key] { return scope }
        // Full language names (code-fence labels) → registered extension.
        let aliasMap: [String: String] = [
            "c++": "cpp", "csharp": "cs", "c#": "cs", "fsharp": "fs",
            "shell": "sh", "bash": "sh", "zsh": "sh", "objective-c": "m", "objc": "m",
            "text": "txt", "plaintext": "txt", "typescript": "ts",
            "javascript": "js", "python": "py", "ruby": "rb", "golang": "go",
            "yml": "yaml", "common-lisp": "lisp", "scheme": "lisp", "racket": "lisp",
            "coffeescript": "coffee", "docker": "dockerfile", "make": "makefile",
            "perl": "pl", "haskell": "hs", "erlang": "erl", "clojure": "clj",
            "elixir": "ex", "visual-basic": "vb", "vb": "vb",
        ]
        if let ext = aliasMap[key], let scope = registry[ext] { return scope }
        return registry[key]
    }

    /// Resolve the grammar file path for a scopeName (dev vs bundled layout).
    private func grammarPath(forScopeName scope: String) -> String? {
        SyntaxLoader.resolveResourceFile("\(scope).tmLanguage", subdirectory: "Syntax/grammars")
    }

    // MARK: - Tokenization

    /// Tokenize `text` for a language id/extension. Returns nil when no grammar
    /// is registered, the daemon is unavailable, or the grammar fails to load.
    func tokenize(_ text: String, language: String) -> [Token]? {
        guard let scope = scopeName(for: language) else { return nil }
        return tokenize(text, scopeName: scope)
    }

    func tokenize(_ text: String, scopeName: String) -> [Token]? {
        let cacheKey = scopeName + "\n" + text
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            touchCache(cacheKey)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let path = grammarPath(forScopeName: scopeName) else { return nil }

        let tokens: [Token]?
        do {
            let response = try RubyBridge.shared.sendSync(
                command: "tokenize",
                arguments: ["grammar_path": path, "text": text],
                timeout: 5.0
            )
            tokens = Self.parseTokens(from: response, text: text)
        } catch {
            tokens = nil
        }

        if let tokens {
            cacheLock.lock()
            cache[cacheKey] = tokens
            cacheOrder.append(cacheKey)
            while cacheOrder.count > maxCacheEntries, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            cacheLock.unlock()
        }
        return tokens
    }

    private func touchCache(_ key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(key)
        }
    }

    /// Parse the daemon's `{ tokens: [{start,end,scope}] }` response into Swift
    /// `Token`s with UTF-16 (NSRange) offsets.
    private static func parseTokens(from response: RubyBridgeResponse, text: String) -> [Token]? {
        guard response.success, let dict = response.resultDict else { return nil }
        if dict["error"] != nil { return nil }
        guard let rawTokens = dict["tokens"] as? [[String: Any]] else { return nil }

        // Ruby reports absolute Unicode-codepoint offsets; NSString indexes by
        // UTF-16 code units. Build a scalar→UTF-16 map once per text.
        var scalarToUTF16: [Int] = []
        scalarToUTF16.reserveCapacity(text.unicodeScalars.count + 1)
        var utf16 = 0
        for scalar in text.unicodeScalars {
            scalarToUTF16.append(utf16)
            utf16 += (scalar.value > 0xFFFF) ? 2 : 1
        }
        scalarToUTF16.append(utf16)

        var tokens: [Token] = []
        tokens.reserveCapacity(rawTokens.count)
        for raw in rawTokens {
            guard let start = raw["start"] as? Int,
                  let end = raw["end"] as? Int,
                  let scope = raw["scope"] as? String,
                  end > start else { continue }
            let s = scalarToUTF16[min(start, scalarToUTF16.count - 1)]
            let e = scalarToUTF16[min(end, scalarToUTF16.count - 1)]
            guard e > s else { continue }
            tokens.append(Token(range: NSRange(location: s, length: e - s),
                                scope: TextMateScopeMapper.map(scope)))
        }

        // Innermost-first ordering: sort by start ascending, then length
        // descending so longer (outer) scopes are applied before shorter (inner)
        // scopes — later application wins, yielding correct nesting precedence.
        return tokens.sorted {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length > $1.range.length
        }
    }
}