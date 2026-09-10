import Foundation

// MARK: - Syntax Config Loader

/// Loads syntax engine configuration from YAML files in Resources/Syntax/.
enum SyntaxLoader {

    // MARK: - Resource Resolution

    /// Locate a YAML resource — tries Bundle.module (SPM), Bundle.main (app bundle), dev path.
    private static func loadYaml(_ name: String, subdirectory: String) -> [String: Any] {
        // 1. App bundle (most reliable for bundled apps)
        if let resURL = Bundle.main.resourceURL {
            let subDir = resURL.appendingPathComponent(subdirectory)
            let fileURL = subDir.appendingPathComponent("\(name).yml")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return SimpleYaml.loadFile(fileURL.path)
            }
        }
        // 2. SPM Bundle.module with subdirectory
        if let url = Bundle.module.url(forResource: name, withExtension: "yml",
                                       subdirectory: subdirectory) {
            return SimpleYaml.loadFile(url.path)
        }
        // 3. SPM Bundle.module flat (SPM flattens directory structure)
        if let url = Bundle.module.url(forResource: name, withExtension: "yml",
                                       subdirectory: nil) {
            return SimpleYaml.loadFile(url.path)
        }
        // 4. Dev path
        let devPath = URL(fileURLWithPath: "AetherCodex/Resources/\(subdirectory)/\(name).yml")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return SimpleYaml.loadFile(devPath.path)
        }
        return [:]
    }

    // MARK: - Heuristic Rules

    /// Load regex rules from heuristic.yml.
    static func loadHeuristicRules() -> [(scope: TokenScope, pattern: String)] {
        let dict = loadYaml("heuristic", subdirectory: "Syntax")
        guard let rules = dict["rules"] as? [[String: Any]] else {
            print("[SyntaxLoader] no rules in heuristic.yml, using built-in defaults")
            return builtInHeuristicRules()
        }

        var result: [(scope: TokenScope, pattern: String)] = []
        for rule in rules {
            guard let scopeStr = rule["scope"] as? String,
                  let scope = TokenScope(rawValue: scopeStr),
                  let pattern = rule["pattern"] as? String
            else { continue }
            result.append((scope: scope, pattern: pattern))
        }
        return result.isEmpty ? builtInHeuristicRules() : result
    }

    // MARK: - Tree-sitter Scope Map

    /// Load node-type → TokenScope mapping from a scope map YAML file.
    static func loadScopeMap(_ name: String) -> [String: TokenScope] {
        let dict = loadYaml(name, subdirectory: "Syntax")
        guard !dict.isEmpty else {
            print("[SyntaxLoader] scope map '\(name)' not found")
            return [:]
        }

        var result: [String: TokenScope] = [:]
        for (nodeType, value) in dict {
            guard let scopeStr = value as? String,
                  let scope = TokenScope(rawValue: scopeStr)
            else { continue }
            result[nodeType] = scope
        }
        return result
    }

    /// Load the languages registry (file extension → grammar name + optional query + scope map).
        static func loadLanguageRegistry() -> [String: LanguageConfig] {
            registryCache
        }

        /// Parsed exactly once and shared. Callers run this per highlight row
        /// (code blocks, CLI shell blocks, the Æther Debug log) — re-reading the
        /// YAML per call would re-parse the registry for every rendered line.
        private static let registryCache: [String: LanguageConfig] = {
            let dict = loadYaml("languages", subdirectory: "Syntax")
            var result: [String: LanguageConfig] = [:]
            for (ext, value) in dict {
                guard let map = value as? [String: Any],
                      let grammar = map["grammar"] as? String
                else { continue }
                let scopeMapFile = map["scopeMap"] as? String
                let queries: [String]
                if let qList = map["queries"] as? [String] {
                    queries = qList
                } else if let qStr = map["queries"] as? String {
                    queries = [qStr]
                } else if let qList = map["query"] as? [String] {
                    queries = qList
                } else if let qStr = map["query"] as? String {
                    queries = [qStr]
                } else {
                    queries = [grammar]
                }
                result[ext] = LanguageConfig(grammar: grammar, scopeMapFile: scopeMapFile, queries: queries)
            }
            return result
        }()

    // MARK: - Built-in Fallback

    private static func builtInHeuristicRules() -> [(scope: TokenScope, pattern: String)] {
        [
            // ── Markdown: fenced code blocks ──
            (.codeBlock,   "(?m)^```[^\\n]*(?:\\n(?!```\\s*$).*)*\\n```\\s*$"),
            (.codeBlock,   "(?m)^~~~[^\\n]*(?:\\n(?!~~~\\s*$).*)*\\n~~~\\s*$"),

            // ── Markdown: ATX headings ──
            (.heading6,    "^#{6}\\s+.*$"),
            (.heading5,    "^#{5}\\s+.*$"),
            (.heading4,    "^#{4}\\s+.*$"),
            (.heading3,    "^#{3}\\s+.*$"),
            (.heading2,    "^#{2}\\s+.*$"),
            (.heading1,    "^#{1}\\s+.*$"),

            // ── Markdown: setext headings ──
            (.heading1,    "^=+\\s*$"),
            (.heading2,    "^-+\\s*$"),

            // ── Markdown: blockquote ──
            (.blockquote,  "^>\\s+.+$"),

            // ── Markdown: thematic break ──
            (.thematicBreak, "^(---|\\*\\*\\*|___)\\s*$"),

            // ── Markdown: emphasis (longer patterns first) ──
            (.strong,      "\\*\\*\\*(.+?)\\*\\*\\*"),
            (.emphasis,    "\\*\\*\\*(.+?)\\*\\*\\*"),
            (.strong,      "___(.+?)___"),
            (.emphasis,    "___(.+?)___"),
            (.strong,      "(?<!\\*)\\*\\*(?!\\*)(.+?)(?<!\\*)\\*\\*(?!\\*)"),
            (.strong,      "(?<!_)__(?!_)(.+?)(?<!_)__(?!_)"),
            (.emphasis,    "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"),
            (.emphasis,    "(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"),

            // ── Markdown: strikethrough ──
            (.strikethrough, "~~.+?~~"),

            // ── Markdown: inline code ──
            (.inlineCode,  "`[^`\\n]+`"),

            // ── Markdown: links ──
            (.string,      "\\]\\([^)]+\\)"),
            (.variable,    "\\[[^\\]]+\\]\\("),

            // ── Markdown: image ──
            (.string,      "\\!\\[[^\\]]*\\]\\[[^\\]]+\\]"),

            // ── Markdown: list markers ──
            (.punctuation, "^\\s*[-*+]\\s"),
            (.punctuation, "^\\s*\\d+\\.\\s"),

            // ── Code (all languages) ──
            // Doc comments before regular — declaration order is priority.
            (.comment,    "///.*"),
            (.comment,    "/\\*\\*[\\s\\S]*?\\*/"),
            (.comment,    "//.*"),
            (.comment,    "/\\*[\\s\\S]*?\\*/"),
            (.comment,    "#.*"),
            (.string,     "\"(?:[^\"\\\\]|\\\\.)*\""),
            (.string,     "'(?:[^'\\\\]|\\\\.)*'"),
            (.number,     "\\b\\d+\\.?\\d*(?:[eE][+-]?\\d+)?\\b"),
            (.keyword,          "\\\\b(if|else|for|while|do|switch|case|default|break|continue|return|throw|try|catch|finally|new|delete|typeof|instanceof|class|struct|enum|protocol|extension|func|var|let|const|import|export|from|as|is|guard|defer|where|in|of|public|private|internal|fileprivate|open|static|final|override|mutating|nonmutating|convenience|required|optional|throws|rethrows|async|await|yield|def|end|module|begin|rescue|ensure|unless|then|elsif|when)\\\\b"),
            (.constantLanguage, "\\\\b(true|false|nil|null|undefined)\\\\b"),
            (.variableLanguage, "\\\\b(self|super)\\\\b"),
            (.entityNameClass,   "(?<=[^.!?\\\\n]\\\\s)\\\\b[A-Z][a-zA-Z0-9]*\\\\b"),
            (.entityNameClass,   "(?<=[\\\\[<])\\\\b[A-Z][a-zA-Z0-9]*\\\\b"),
            (.entityNameFunction,"\\\\b(?!if|for|while|switch|catch|return|import|export|guard|defer)[a-z_]\\\\w*(?=\\\\s*\\\\()"),
            (.keyword,          "[+\\\\-*/%=<>!&|^~?:]+|->|=>|\\\\.{2,3}"),
            (.punctuation, "[{}()\\[\\];,.]"),
        ]
    }
}

// MARK: - Language Config

struct LanguageConfig {
    let grammar: String
    let scopeMapFile: String?
    let queries: [String]
}