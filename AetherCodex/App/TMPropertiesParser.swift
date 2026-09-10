import Foundation

// MARK: - TMProperties Data Types

/// A single section within a `.aether-properties` file.
struct TMPropertiesSection {
    /// The section selector (e.g., `"source.ruby"`, `"*.md"`).
    /// `nil` for the root (unscoped) section.
    let selector: String?
    /// Whether this selector is a glob pattern (true) or a scope selector (false).
    let isGlob: Bool
    /// Raw key-value settings — variable references (`$VAR`) are NOT yet resolved.
    let settings: [String: String]
}

/// Parsed representation of a `.aether-properties` file.
struct TMPropertiesFile {
    let path: String
    /// Variable definitions: `$VAR = value` (raw, may contain `$OTHER` refs).
    let variables: [String: String]
    /// Ordered sections (root section first, then in file order).
    let sections: [TMPropertiesSection]

    // MARK: - Variable Resolution

    /// Resolve `${VAR}` and `$VAR` references in a string value.
    /// Uses file variables merged with `extraVars` (e.g., `CWD`, `TM_DISPLAYNAME`).
    func resolveVariables(in value: String, extraVars: [String: String] = [:]) -> String {
        var merged = variables
        for (k, v) in extraVars { merged[k] = v }
        return Self.interpolate(value, variables: merged)
    }

    /// Expand variable references using the provided dictionary.
    /// Handles both `$VAR` and `${VAR}` syntax. Unresolved references are left intact.
    static func interpolate(_ input: String, variables: [String: String]) -> String {
        // Matches $VAR or ${VAR} — VAR starts with letter/underscore, then alphanumeric/underscore
        let pattern = try! NSRegularExpression(
            pattern: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"#
        )
        let nsInput = input as NSString
        var result = input
        let matches = pattern.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        // Process in reverse so replacement ranges stay valid
        for match in matches.reversed() {
            let fullRange = match.range
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let varName = nsInput.substring(with: nameRange)
            if let value = variables[varName] {
                result = (result as NSString).replacingCharacters(in: fullRange, with: value)
            }
        }
        return result
    }
}

// MARK: - Parser

/// Line-based state-machine parser for `.aether-properties` (INI-format scope-settings) files.
///
/// Grammar:
/// ```
/// file       := (comment | blank | varDef | setting | section)*
/// comment    := '#' .* \n
/// blank      := \n
/// varDef     := '$' name '=' value
/// setting    := key '=' value
/// section    := '[' selector ']'
/// selector   := scope | glob
/// ```
///
/// Two-pass approach: first pass collects all raw settings and variable definitions;
/// second pass (via `TMPropertiesFile.resolveVariables`) handles interpolation.
final class TMPropertiesParser {

    // MARK: - Public

    /// Parse a `.aether-properties` file at the given path. Returns `nil` if unreadable.
    static func parse(fileAt path: String) -> TMPropertiesFile? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return parse(content: content, path: path)
    }

    /// Parse `.aether-properties` content string.
    static func parse(content: String, path: String) -> TMPropertiesFile {
        var variables: [String: String] = [:]
        var sections: [TMPropertiesSection] = []

        var currentSelector: String? = nil
        var currentIsGlob = false
        var currentSettings: [String: String] = [:]

        let lines = content.components(separatedBy: .newlines)

        func flushSection() {
            // Always emit the current section (even if empty) to preserve section order
            sections.append(TMPropertiesSection(
                selector: currentSelector,
                isGlob: currentIsGlob,
                settings: currentSettings
            ))
            currentSelector = nil
            currentIsGlob = false
            currentSettings = [:]
        }

        for rawLine in lines {
            // Strip comment (but not inside quoted strings — simple heuristic)
            var line = rawLine
            if let commentIdx = line.firstIndex(of: "#") {
                line = String(line[..<commentIdx])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Section header: [ selector ]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushSection()
                let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                currentSelector = inner.isEmpty ? nil : inner
                currentIsGlob = currentSelector.map { isGlobSelector($0) } ?? false
                continue
            }

            // Key = value  or  $VAR = value
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let rawVal = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            let val = stripQuotes(rawVal)

            if key.hasPrefix("$") {
                let varName = String(key.dropFirst())
                variables[varName] = val
            } else {
                currentSettings[key] = val
            }
        }

        flushSection()

        return TMPropertiesFile(path: path, variables: variables, sections: sections)
    }

    // MARK: - Helpers

    /// Strip surrounding double or single quotes from a value string.
    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Glob Detection

    /// Determine whether a section selector is a glob pattern.
    /// Scope selectors only contain alphanumerics and dots.
    /// Glob selectors contain wildcards, braces, slashes, or are quoted.
    private static func isGlobSelector(_ raw: String) -> Bool {
        // Strip optional surrounding quotes
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let globChars = CharacterSet(charactersIn: "*/?{}[]")
        return stripped.rangeOfCharacter(from: globChars) != nil
            || stripped.contains("/")
    }
}

// MARK: - Glob Matching

extension TMPropertiesParser {

    /// Check if a glob pattern matches a file path.
    /// Brace expansion is applied before matching.
    static func matchesGlob(_ glob: String, path: String) -> Bool {
        let stripped = glob.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let patterns = expandBraces(in: stripped)
        for pat in patterns {
            if matchesSingle(pat, path: path) { return true }
        }
        return false
    }

    // MARK: - Brace Expansion

    /// Expand `{a,b,c}` patterns into individual strings. Handles nested braces.
    private static func expandBraces(in pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
              let close = pattern[open...].firstIndex(of: "}") else {
            return [pattern]
        }
        let prefix = String(pattern[..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let inner = String(pattern[pattern.index(after: open)..<close])
        let options = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for opt in options {
            let expanded = prefix + opt + suffix
            result.append(contentsOf: expandBraces(in: expanded))
        }
        return result
    }

    // MARK: - Wildcard Matching

    /// Match a single glob pattern (no braces) against a file path.
    /// `*` matches any sequence (including `/`), `?` matches any single character.
    /// The pattern may match any suffix of the path.
    private static func matchesSingle(_ pattern: String, path: String) -> Bool {
        // Convert glob to regex
        var regexPattern = ""
        for ch in pattern {
            switch ch {
            case "*":  regexPattern += ".*"
            case "?":  regexPattern += "."
            case ".":  regexPattern += "\\."
            case "+", "^", "$", "(", ")", "[", "]", "|", "\\":
                regexPattern += "\\\\(ch)"
            default:   regexPattern.append(ch)
            }
        }
        // Match anywhere in the path (suffix match)
        let regex = try! NSRegularExpression(pattern: regexPattern, options: [])
        let range = NSRange(location: 0, length: (path as NSString).length)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }
}