import Foundation
import AetherOracleResources

// MARK: - Minimal YAML Parser

/// Parses a strict subset of YAML sufficient for our config files:
/// - Key: value pairs (scalar values)
/// - Nested maps via 2-space indentation
/// - Arrays via `- ` prefix
/// - Comments (# to end of line)
/// - Double-quoted, single-quoted, and unquoted strings
/// - Integer, float, boolean scalars
///
/// No anchors, aliases, tags, block scalars, or flow style.
enum SimpleYaml {

    // MARK: - Public API

    static func load(_ yaml: String) -> [String: Any] {
        let lines = yaml.components(separatedBy: "\n")
        let (result, _) = parseMap(lines: lines, startIndex: 0, indent: 0)
        return result
    }

    static func loadFile(_ path: String) -> [String: Any] {
        guard let yaml = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("[SimpleYaml] cannot read: \(path)")
            return [:]
        }
        return load(yaml)
    }

    static func loadResource(_ name: String, subdirectory: String? = nil) -> [String: Any] {
        // 1. App bundle (most reliable for bundled apps)
        if let resURL = Bundle.main.resourceURL {
            let path: String
            if let sub = subdirectory {
                path = resURL.appendingPathComponent(sub).appendingPathComponent("\(name).yml").path
            } else {
                path = resURL.appendingPathComponent("\(name).yml").path
            }
            if FileManager.default.fileExists(atPath: path) {
                return loadFile(path)
            }
        }
        // 2. SPM AetherOracleResources.bundle
        if let url = AetherOracleResources.bundle.url(
            forResource: name, withExtension: "yml", subdirectory: subdirectory
        ) {
            return loadFile(url.path)
        }
        // 3. Dev path
        let devPath: String
        if let sub = subdirectory {
            devPath = "AetherOracle/resources/\(sub)/\(name).yml"
        } else {
            devPath = "AetherOracle/resources/\(name).yml"
        }
        if FileManager.default.fileExists(atPath: devPath) {
            return loadFile(devPath)
        }
        print("[SimpleYaml] resource not found: \(name).yml")
        return [:]
    }

    // MARK: - Parsing

    private static func parseMap(lines: [String], startIndex: Int, indent: Int)
        -> ([String: Any], Int)
    {
        var result: [String: Any] = [:]
        var i = startIndex

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            let lineIndent = countIndent(line)

            // If indent is less than expected, pop back to parent
            if lineIndent < indent { break }

            // If indent is greater than expected, skip (malformed)
            if lineIndent > indent { i += 1; continue }

            // Array item
            if trimmed.hasPrefix("- ") {
                let (arr, nextIdx) = parseArray(lines: lines, startIndex: i, indent: indent)
                i = nextIdx
                // Arrays at map level become a special key
                // (but in our config, arrays only appear as values of a key)
                // If we encounter a bare array, store it under empty key
                result[""] = arr
                continue
            }

            // Key: value
            guard let colonIdx = findColon(in: trimmed) else {
                i += 1
                continue
            }

            var key = String(trimmed[trimmed.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes from keys (just like parseScalar does for values).
            // YAML keys may be quoted: \"entity.name.class\" → entity.name.class
            if (key.hasPrefix("\"") && key.hasSuffix("\"")) ||
               (key.hasPrefix("'") && key.hasSuffix("'")) {
                key = String(key.dropFirst().dropLast())
            }
            var afterColon = trimmed[trimmed.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)

            // Strip inline comment: "value # comment" → "value", "# comment" → ""
            if let hashIdx = afterColon.firstIndex(of: "#") {
                // Only strip if # is preceded by space/start or at start
                let beforeHash = afterColon[afterColon.startIndex..<hashIdx]
                if beforeHash.isEmpty || beforeHash.last == " " {
                    afterColon = String(beforeHash).trimmingCharacters(in: .whitespaces)
                }
            }

            if afterColon.isEmpty {
                // Nested map or array on subsequent lines.
                // Skip comment/blank lines before peeking — otherwise
                // "rules:\n  # comment\n  - scope: ..." is parsed as
                // a map instead of an array, and the array cast fails.
                i += 1
                while i < lines.count {
                    let peekLine = lines[i]
                    let peekTrimmed = peekLine.trimmingCharacters(in: .whitespaces)
                    if peekTrimmed.isEmpty || peekTrimmed.hasPrefix("#") { i += 1; continue }
                    if peekTrimmed.hasPrefix("- ") {
                        let (arr, nextIdx) = parseArray(lines: lines, startIndex: i,
                                                          indent: indent + 2)
                        result[key] = arr
                        i = nextIdx
                    } else {
                        let (nested, nextIdx) = parseMap(lines: lines, startIndex: i,
                                                           indent: indent + 2)
                        result[key] = nested
                        i = nextIdx
                    }
                    break
                }
            } else {
                // Inline scalar value
                result[key] = parseScalar(String(afterColon))
                i += 1
            }
        }

        return (result, i)
    }

    private static func parseArray(lines: [String], startIndex: Int, indent: Int)
        -> ([Any], Int)
    {
        var result: [Any] = []
        var i = startIndex

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            let lineIndent = countIndent(line)
            if lineIndent < indent { break }
            if lineIndent > indent { i += 1; continue }

            guard trimmed.hasPrefix("- ") else { i += 1; continue }

            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)

            if value.isEmpty {
                // Map item on subsequent lines
                i += 1
                let (nested, nextIdx) = parseMap(lines: lines, startIndex: i,
                                                   indent: indent + 2)
                result.append(nested)
                i = nextIdx
            } else if let colonIdx = findColon(in: value),
                      !value[value.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces).isEmpty {
                // Syntax rule lists use a map beginning on the same line as '-'.
                let key = String(value[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let scalar = String(value[value.index(after: colonIdx)...])
                i += 1
                let (rest, nextIdx) = parseMap(lines: lines, startIndex: i, indent: indent + 2)
                var item = rest
                item[key] = parseScalar(scalar)
                result.append(item)
                i = nextIdx
            } else if let colonIdx = findColon(in: value),
                      value[value.index(after: colonIdx)...]
                          .trimmingCharacters(in: .whitespaces).isEmpty {
                // "- key:" — nested map
                let key = String(value[value.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                i += 1
                let (nested, nextIdx) = parseMap(lines: lines, startIndex: i,
                                                   indent: indent + 2)
                var item: [String: Any] = [:]
                item[key] = nested
                result.append(item)
                i = nextIdx
            } else {
                result.append(parseScalar(value))
                i += 1
            }
        }

        return (result, i)
    }

    // MARK: - Helpers

    private static func countIndent(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }  // treat tab as 2 spaces
            else { break }
        }
        return count
    }

    private static func findColon(in trimmed: String) -> String.Index? {
        // Find first colon not inside quotes
        var inSingle = false
        var inDouble = false
        for i in trimmed.indices {
            let ch = trimmed[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == ":" && !inSingle && !inDouble {
                return i
            }
        }
        return nil
    }

    private static func parseScalar(_ raw: String) -> Any {
        var s = raw.trimmingCharacters(in: .whitespaces)

        // Remove surrounding quotes
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
           (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }

        // Try parsing as various number formats
        // Must check for hex strings FIRST — don't let Int() truncate them
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return s  // Keep hex color strings as strings
        }
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        if s == "true" { return true }
        if s == "false" { return false }

        // Null
        if s == "null" || s == "nil" || s == "~" { return NSNull() }

        // Integer (but NOT hex strings like "0xRRGGBB")
        if !s.hasPrefix("0x") && !s.hasPrefix("0X") {
            if let i = Int(s) { return i }
        }

        // Float (but NOT hex)
        if !s.hasPrefix("0x") && !s.hasPrefix("0X") {
            if let d = Double(s) { return d }
        }

        // String (includes hex color values like "0xC759C7")
        return s
    }
}
