import Foundation

// MARK: - Tree-Sitter Scope Mapper

/// Maps tree-sitter language names to TextMate-style scope selectors.
/// Provides the bridge between our language registry and `.aether-properties` scope keys.
enum TreeSitterScopeMapper {

    // MARK: - Language → Scope

    /// Language name → base TextMate scope selector.
    private static let languageToScope: [String: String] = [
        "swift":      "source.swift",
        "ruby":       "source.ruby",
        "rust":       "source.rust",
        "javascript": "source.js",
        "typescript": "source.ts",
        "tsx":        "source.tsx",
        "python":     "source.python",
        "c":          "source.c",
        "cpp":        "source.cpp",
        "go":         "source.go",
        "java":       "source.java",
        "kotlin":     "source.kotlin",
        "shell":      "source.shell",
        "bash":       "source.shell",
        "zsh":        "source.shell",
        "yaml":       "source.yaml",
        "json":       "source.json",
        "xml":        "text.xml",
        "plist":      "text.xml",
        "html":       "text.html.basic",
        "css":        "source.css",
        "scss":       "source.css",
        "less":       "source.css",
        "markdown":   "text.html.markdown",
        "text":       "text.plain",
    ]

    // MARK: - Extension → Language

    /// File extension → language name (canonical form for languageToScope lookup).
    private static let extToLanguage: [String: String] = [
            "swift": "swift",
            "rb":    "ruby",
            "rs":    "rust",
            "js":    "javascript",
            "ts":    "typescript",
            "tsx":   "tsx",
            "py":    "python",
            "c":     "c",
            "cpp":   "cpp",
            "cc":    "cpp",
            "cxx":   "cpp",
            "hpp":   "cpp",
            "h":     "c",
            "go":    "go",
            "java":  "java",
            "kt":    "kotlin",
            "kts":   "kotlin",
            "sh":    "shell",
            "bash":  "bash",
            "zsh":   "zsh",
            "yaml":  "yaml",
            "yml":   "yaml",
            "json":  "json",
            "xml":   "xml",
            "plist": "plist",
            "html":  "html",
            "htm":   "html",
            "css":   "css",
            "scss":  "scss",
            "less":  "less",
            "php":   "php",
            "md":    "markdown",
            "mkdn":  "markdown",
            "markdown": "markdown",
            "txt":   "text",
            "text":  "text",
        ]

    // MARK: - Public API

    /// Get the base TextMate scope for a file extension.
    /// Returns nil for unknown extensions.
    static func scope(forExtension ext: String) -> String? {
        guard let lang = extToLanguage[ext.lowercased()] else { return nil }
        return languageToScope[lang]
    }

    /// Get the language name for a file extension.
    /// Returns nil for unknown extensions.
    static func language(forExtension ext: String) -> String? {
        return extToLanguage[ext.lowercased()]
    }

    /// Get all ancestor scopes from most specific to root.
    /// e.g., `"source.ruby.rails"` → `["source.ruby.rails", "source.ruby", "source"]`
    /// Returns empty array for empty input.
    static func ancestorScopes(for scope: String) -> [String] {
        guard !scope.isEmpty else { return [] }
        var scopes: [String] = [scope]
        var current = scope
        while let dotIndex = current.lastIndex(of: ".") {
            current = String(current[..<dotIndex])
            scopes.append(current)
        }
        return scopes
    }
}