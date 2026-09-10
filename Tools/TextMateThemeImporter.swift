#!/usr/bin/env swift
import Foundation

// MARK: - TextMate Theme Importer
// Converts .tmTheme (XML plist) files to AetherCodex hermetic.yml theme format.
//
// Usage: swift TextMateThemeImporter.swift path/to/theme.tmTheme [output.yml]
//
// TextMate themes: ~/Library/Application Support/TextMate/Themes/
// Also available from: https://github.com/textmate/themes

// MARK: - TokenScope mapping

/// Maps TextMate scope selectors to AetherCodex TokenScope values.
/// TextMate uses space-separated AND-selectors (e.g., "source comment.block")
/// where the rightmost dot-path is the actual token type.
struct ScopeMapper {
    /// Ordered by specificity — longer/more specific first
    static let map: [(pattern: String, scope: String)] = [
        // Markdown / markup (specific → general)
        ("markup.heading.1", "markup.heading.1"),
        ("markup.heading.2", "markup.heading.2"),
        ("markup.heading.3", "markup.heading.3"),
        ("markup.heading.4", "markup.heading.4"),
        ("markup.heading.5", "markup.heading.5"),
        ("markup.heading.6", "markup.heading.6"),
        ("markup.heading", "markup.heading"),
        ("markup.italic", "markup.italic"),
        ("markup.bold", "markup.bold"),
        ("markup.strikethrough", "markup.strikethrough"),
        ("markup.quote", "markup.quote"),
        ("markup.rule", "markup.rule"),
        ("markup.link.url", "markup.link.url"),
        ("markup.link", "markup.link"),
        ("markup.raw.block", "markup.code.block"),
        ("markup.raw.inline", "markup.code.inline"),
        ("markup.checked", "markup.list.checked"),
        ("markup.list", "markup"),
        ("markup", "markup"),

        // String sub-scopes
        ("string.escape", "string.escape"),
        ("string.regexp", "string"),
        ("string.interpolated", "string"),
        ("string.literal", "string"),
        ("string", "string"),

        // Keyword sub-scopes
        ("keyword.type", "keyword.type"),
        ("keyword.control", "keyword"),
        ("keyword.operator", "operator"),
        ("keyword.preprocessor", "keyword"),
        ("keyword.other.unit", "keyword"),
        ("keyword.other", "keyword"),
        ("keyword", "keyword"),

        // Constant sub-scopes
        ("constant.numeric", "constant.numeric"),
        ("constant.language", "support.constant"),
        ("constant.character.escape", "string.escape"),
        ("constant.character", "string"),
        ("constant.symbol", "constant.symbol"),
        ("constant.other.rgb-value", "constant"),
        ("constant.other", "constant"),
        ("constant", "constant"),

        // Variable sub-scopes
        ("variable.language", "variable.language"),
        ("variable.parameter", "variable"),
        ("variable.other.member", "variable.instance"),
        ("variable.other.property", "property"),
        ("variable.other.readwrite", "variable"),
        ("variable.other.constant", "variable"),
        ("variable.other", "variable"),
        ("variable", "variable"),

        // Support sub-scopes
        ("support.function.activerecord", "support.function"),
        ("support.function.event-handler", "support.function"),
        ("support.function.any-method", "function"),
        ("support.function", "support.function"),
        ("support.type.property-name", "support.type"),
        ("support.type", "support.type"),
        ("support.class.prototype", "support.type"),
        ("support.class", "support.type"),
        ("support.constant", "support.constant"),
        ("support.variable", "variable"),
        ("support", "variable"),

        // Storage (Swift: var/let/class/struct)
        ("storage.type.function", "function"),
        ("storage.type", "keyword.type"),
        ("storage.modifier", "keyword"),
        ("storage", "keyword"),

        // Entity — function/class/tag names
        ("entity.name.function", "function"),
        ("entity.name.type", "type"),
        ("entity.name.class", "type"),
        ("entity.name.struct", "type"),
        ("entity.name.enum", "type"),
        ("entity.name.tag.wildcard", "tag"),
        ("entity.name.tag", "tag"),
        ("entity.other.inherited-class", "type"),
        ("entity.other.attribute-name.pseudo-class", "attribute"),
        ("entity.other.attribute-name.id", "attribute"),
        ("entity.other.attribute-name.class", "attribute"),
        ("entity.other.attribute-name", "attribute"),
        ("entity.name", "type"),
        ("entity", "type"),

        // Meta — inline/block tag wrappers
        ("meta.preprocessor", "preprocessor"),
        ("meta.selector", "tag"),
        ("meta.tag.inline", "tag"),
        ("meta.tag.block", "tag"),
        ("meta.tag", "tag"),
        ("meta", "plain"),

        // Comment sub-scopes
        ("comment.line.documentation", "comment"),
        ("comment.block.documentation", "comment"),
        ("comment.line", "comment"),
        ("comment.block", "comment"),
        ("comment", "comment"),

        // Punctuation
        ("punctuation.definition.tag", "punctuation"),
        ("punctuation.definition.string", "punctuation"),
        ("punctuation.section", "punctuation"),
        ("punctuation.separator", "punctuation"),
        ("punctuation.terminator", "punctuation"),
        ("punctuation", "punctuation"),

        // Object/property (JS prototype)
        ("object.property.function", "function"),

        // Invalid
        ("invalid.deprecated", "invalid"),
        ("invalid.illegal", "invalid"),
        ("invalid", "invalid"),
    ]

    /// Resolve a TextMate scope selector string to an AetherCodex scope.
    /// Handles space-separated AND-selectors by trying each path component.
    static func resolve(_ textMateScope: String) -> String {
        // Split into space-separated path components
        // e.g., "source comment.block" → ["source", "comment.block"]
        let paths = textMateScope.components(separatedBy: " ")
        var best: String? = nil
        var bestLen = 0

        for path in paths {
            // Try the path and each dot-separated suffix
            // e.g., "comment.block.documentation" →
            //   "comment.block.documentation", "comment.block", "comment"
            let parts = path.components(separatedBy: ".")
            for i in stride(from: parts.count, through: 1, by: -1) {
                let candidate = parts[0..<i].joined(separator: ".")
                for (pattern, scope) in map {
                    if candidate == pattern, pattern.count > bestLen {
                        best = scope
                        bestLen = pattern.count
                    }
                }
            }
        }

        return best ?? "plain"
    }
}

// MARK: - Color parsing

func parseHexColor(_ hex: String) -> String? {
    var h = hex.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    // Handle 3-char shorthand
    if h.count == 3 {
        h = h.map { "\($0)\($0)" }.joined()
    }
    guard h.count == 6, let _ = Int(h, radix: 16) else { return nil }
    return "0x\(h.uppercased())"
}

/// Calculate a reasonable editor background opacity from the background color.
/// Darker backgrounds → higher opacity (less glass, more solid theme base).
func opacityFromBackground(_ hex: String, kind: String) -> String {
    let raw = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    guard raw.count == 6,
          let r = Int(raw.prefix(2), radix: 16),
          let g = Int(raw.dropFirst(2).prefix(2), radix: 16),
          let b = Int(raw.suffix(2), radix: 16) else {
        return kind == "dark" ? "0.78" : "0.62"
    }
    let brightness = Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114
    // Dark themes: 0–60 brightness → 0.88–0.55 opacity (blacker = more opaque)
    // Light themes: 200–255 brightness → 0.70–0.50 opacity (whiter = slightly more opaque)
    if kind == "dark" {
        let t = min(max(brightness / 60.0, 0.0), 1.0)
        return String(format: "%.2f", 0.88 - t * 0.33)
    } else {
        let t = min(max((brightness - 200.0) / 55.0, 0.0), 1.0)
        return String(format: "%.2f", 0.55 + t * 0.15)
    }
}

// MARK: - Plist parsing (minimal XML plist parser)

func parsePlist(_ xml: String) -> [String: Any]? {
    // Use PropertyListSerialization — but for XML, we need to handle the DTD
    // Strip the DOCTYPE line which causes issues
    var cleaned = xml
    if let doctypeRange = cleaned.range(of: "<!DOCTYPE[^>]*>", options: .regularExpression) {
        cleaned.removeSubrange(doctypeRange)
    }
    guard let data = cleaned.data(using: .utf8) else { return nil }
    do {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return plist as? [String: Any]
    } catch {
        // Try legacy format
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil)
            return plist as? [String: Any]
        } catch {
            print("// Error parsing plist: \(error)")
            return nil
        }
    }
}

// MARK: - Main importer

func importTheme(from path: String, themeTags: [String] = []) -> String {
    guard FileManager.default.fileExists(atPath: path) else {
        return "# Error: file not found: \(path)"
    }
    
    guard let xml = try? String(contentsOfFile: path, encoding: .utf8) else {
        return "# Error: cannot read file: \(path)"
    }
    
    guard let plist = parsePlist(xml) else {
        return "# Error: invalid plist: \(path)"
    }
    
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let settings = plist["settings"] as? [[String: Any]] ?? []
    
    var globalFg: String = "0xBFBFB8"
    var globalBg: String = "0x1A1A1A"
    var caret: String = "0xBFBFB8"
    var selection: String = "0x333366"
    var lineHighlight: String = "0x232323"
    var kind = "dark"
    
    var scopeStyles: [(scope: String, color: String?, bg: String?, bold: Bool, italic: Bool, underline: Bool)] = []
    
    for entry in settings {
        guard let entryDict = entry as? [String: Any] else { continue }
        let innerSettings = entryDict["settings"] as? [String: Any] ?? [:]
        
        if entryDict["scope"] == nil {
            // Global settings
            if let bgStr = innerSettings["background"] as? String, let c = parseHexColor(bgStr) {
                globalBg = c
                // Auto-detect light/dark from background brightness
                let hex = c.dropFirst(2)
                if let r = Int(hex.prefix(2), radix: 16),
                   let g = Int(hex.dropFirst(2).prefix(2), radix: 16),
                   let b = Int(hex.suffix(2), radix: 16) {
                    let brightness = (Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114)
                    kind = brightness > 128 ? "light" : "dark"
                }
            }
            if let fgStr = innerSettings["foreground"] as? String, let c = parseHexColor(fgStr) {
                globalFg = c
            }
            if let cStr = innerSettings["caret"] as? String, let c = parseHexColor(cStr) {
                caret = c
            }
            if let sStr = innerSettings["selection"] as? String, let c = parseHexColor(sStr) {
                selection = c
            }
            if let lStr = innerSettings["lineHighlight"] as? String, let c = parseHexColor(lStr) {
                lineHighlight = c
            }
        } else {
            // Scoped settings
            let scopeStr = entryDict["scope"] as? String ?? ""
            let fontStyle = innerSettings["fontStyle"] as? String ?? ""
            let isBold = fontStyle.contains("bold")
            let isItalic = fontStyle.contains("italic")
            let isUnderline = fontStyle.contains("underline")
            
            var fgColor: String? = nil
            var bgColor: String? = nil
            if let fStr = innerSettings["foreground"] as? String, let c = parseHexColor(fStr) { fgColor = c }
            if let bStr = innerSettings["background"] as? String, let c = parseHexColor(bStr) { bgColor = c }
            
            // Skip entries that have no color AND no traits AND no background
            // (e.g., fontStyle-only resets in TextMate themes)
            let hasContent = fgColor != nil || bgColor != nil || isBold || isItalic || isUnderline
            guard hasContent else { continue }
            
            // Split comma-separated scopes
            let scopes = scopeStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for scope in scopes {
                let mapped = ScopeMapper.resolve(scope)
                scopeStyles.append((scope: mapped, color: fgColor, bg: bgColor, bold: isBold, italic: isItalic, underline: isUnderline))
            }
        }
    }
    
    // Merge: deduplicate by scope. TextMate semantics: later entries override
    // specific properties but inherit earlier values for unset properties.
    // A later entry with bold+italic but no foreground color must preserve the
    // earlier foreground — otherwise trait-only entries wipe out colors.
    var merged: [String: (color: String?, bg: String?, bold: Bool, italic: Bool, underline: Bool, rawScope: String)] = [:]
    for s in scopeStyles {
        if let prev = merged[s.scope] {
            merged[s.scope] = (
                color: s.color ?? prev.color,
                bg: s.bg ?? prev.bg,
                bold: s.bold || prev.bold,
                italic: s.italic || prev.italic,
                underline: s.underline || prev.underline,
                rawScope: s.scope
            )
        } else {
            merged[s.scope] = (s.color, s.bg, s.bold, s.italic, s.underline, s.scope)
        }
    }
    
    // Generate YAML
    var yaml = ""
    yaml += "# Converted from TextMate theme: \(name)\n"
    yaml += "# Source: \(path)\n"
    yaml += "name: \(name)\n"
    yaml += "kind: \(kind)\n"
    if !themeTags.isEmpty { yaml += "tags: [\(themeTags.joined(separator: ", "))]\n" }
    yaml += "glassTint: \(kind == "dark" ? "0.70" : "0.30")\n"
    yaml += "editorBackgroundOpacity: \(opacityFromBackground(globalBg, kind: kind))\n"
    yaml += "\n"
    yaml += "# Global editor colors\n"
    yaml += "editor:\n"
    yaml += "  background: \"\(globalBg)\"\n"
    yaml += "  foreground: \"\(globalFg)\"\n"
    yaml += "  caret: \"\(caret)\"\n"
    yaml += "  selection: \"\(selection)\"\n"
    yaml += "  lineHighlight: \"\(lineHighlight)\"\n"
    yaml += "\n"
    yaml += "scopes:\n"
    
    let sortedScopes = merged.keys.sorted()
    for scope in sortedScopes {
        guard let s = merged[scope] else { continue }
        let hasTraits = s.bold || s.italic || s.underline
        let hasBg = s.bg != nil
        
        if !hasTraits && !hasBg, let c = s.color {
            yaml += "  \(scope): \"\(c)\"\n"
        } else {
            yaml += "  \(scope):\n"
            if let c = s.color { yaml += "    color: \"\(c)\"\n" }
            if let b = s.bg { yaml += "    background: \"\(b)\"\n" }
            if s.bold { yaml += "    bold: true\n" }
            if s.italic { yaml += "    italic: true\n" }
            if s.underline { yaml += "    underline: true\n" }
        }
    }
    
    // Ensure plain is always defined
    if merged["plain"] == nil {
        yaml += "  plain: \"\(globalFg)\"\n"
    }
    
    return yaml
}

// MARK: - CLI

let args = CommandLine.arguments
var tagsArg: [String] = []
var inputPath: String? = nil
var outputPath: String? = nil

var i = 1
while i < args.count {
    let a = args[i]
    if a == "--tags", i + 1 < args.count {
        i += 1
        tagsArg = args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    } else if a.hasPrefix("--tags=") {
        let val = String(a.dropFirst(7))
        tagsArg = val.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    } else if inputPath == nil {
        inputPath = a
    } else if outputPath == nil {
        outputPath = a
    }
    i += 1
}

guard let inputPath = inputPath else {
    print("Usage: swift TextMateThemeImporter.swift [--tags vibrant,dark,ink] <path/to/theme.tmTheme> [output.yml]")
    print("")
    print("TextMate themes are typically at:")
    print("  ~/Library/Application Support/TextMate/Themes/")
    print("  Or download from: https://github.com/textmate/themes")
    exit(1)
}

let output = importTheme(from: inputPath, themeTags: tagsArg)

if let out = outputPath {
    try? output.write(toFile: out, atomically: true, encoding: .utf8)
    print("✅ Theme written to \(out)")
} else {
    print(output)
}