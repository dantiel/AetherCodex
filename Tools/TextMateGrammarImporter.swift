#!/usr/bin/env swift
import Foundation

// MARK: - TextMate Grammar Importer
// Converts .tmLanguage (JSON/Plist/XML) files to AetherCodex heuristic.yml rules.
//
// Usage: swift TextMateGrammarImporter.swift path/to/grammar.tmLanguage [output.yml]
//
// TextMate bundles: ~/Library/Application Support/TextMate/Bundles/
// GitHub: github.com/textmate/ — each bundle has Syntaxes/*.tmLanguage

// MARK: - Scope mapping (TextMate scope → AetherCodex TokenScope)

let scopeMap: [String: String] = [
    // Comments
    "comment": "comment",
    "comment.line": "comment",
    "comment.block": "comment",
    "comment.line.double-slash": "comment",
    "comment.line.number-sign": "comment",
    "comment.block.documentation": "comment",
    
    // Keywords
    "keyword": "keyword",
    "keyword.control": "keyword",
    "keyword.operator": "operator",
    "keyword.other": "keyword",
    "storage.type": "keyword.type",
    "storage.modifier": "keyword",
    
    // Strings
    "string": "string",
    "string.quoted.double": "string",
    "string.quoted.single": "string",
    "string.quoted.triple": "string",
    "string.quoted.other": "string",
    "string.interpolated": "string",
    "string.regexp": "string",
    "string.escape": "string.escape",
    
    // Numbers
    "constant.numeric": "constant.numeric",
    "constant.numeric.integer": "constant.numeric",
    "constant.numeric.float": "constant.numeric",
    "constant.numeric.hex": "constant.numeric",
    "constant.numeric.octal": "constant.numeric",
    
    // Constants
    "constant.language": "support.constant",
    "constant.character": "string",
    "constant.other": "constant",
    
    // Variables
    "variable": "variable",
    "variable.language": "variable.language",
    "variable.parameter": "variable",
    "variable.other.member": "variable.instance",
    "variable.other.property": "property",
    "variable.other": "variable",
    
    // Support
    "support.function": "support.function",
    "support.function.builtin": "support.function",
    "support.type": "support.type",
    "support.class": "support.type",
    "support.constant": "support.constant",
    
    // Entity
    "entity.name.function": "function",
    "entity.name.type": "type",
    "entity.name.class": "type",
    "entity.name.struct": "type",
    "entity.name.enum": "type",
    "entity.name.tag": "tag",
    "entity.other.attribute-name": "attribute",
    
    // Meta
    "meta.preprocessor": "preprocessor",
    
    // Punctuation
    "punctuation": "punctuation",
    "punctuation.definition.comment": "punctuation",
    "punctuation.definition.string": "punctuation",
    "punctuation.definition.tag": "punctuation",
    "punctuation.separator": "punctuation",
    "punctuation.terminator": "punctuation",
    
    // Markup
    "markup.heading": "markup.heading",
    "markup.heading.1": "markup.heading.1",
    "markup.heading.2": "markup.heading.2",
    "markup.heading.3": "markup.heading.3",
    "markup.heading.4": "markup.heading.4",
    "markup.heading.5": "markup.heading.5",
    "markup.heading.6": "markup.heading.6",
    "markup.italic": "markup.italic",
    "markup.bold": "markup.bold",
    "markup.quote": "markup.quote",
    "markup.raw.block": "markup.code.block",
    "markup.raw.inline": "markup.code.inline",
    "markup.link": "markup.link",
    "markup.underline.link": "markup.link.url",
    "markup.list": "punctuation",
    "markup.rule": "markup.rule",
    "markup.strikethrough": "markup.strikethrough",
    
    // Invalid
    "invalid": "invalid",
    "invalid.illegal": "invalid",
    "invalid.deprecated": "invalid",
]

func mapScope(_ textMateScope: String) -> String {
    if let mapped = scopeMap[textMateScope] { return mapped }
    // Try prefix matching
    var best: (len: Int, scope: String)? = nil
    for (key, val) in scopeMap {
        if textMateScope.hasPrefix(key), key.count > (best?.len ?? 0) {
            best = (key.count, val)
        }
    }
    return best?.scope ?? "plain"
}

// MARK: - JSON/Plist parsing

func parseGrammar(_ path: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    
    // Try JSON first
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return json
    }
    
    // Try Plist (XML or binary)
    if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
        return plist
    }
    
    // Try XML Plist with DOCTYPE stripping
    if var xml = String(data: data, encoding: .utf8) {
        if let doctypeRange = xml.range(of: "<!DOCTYPE[^>]*>", options: .regularExpression) {
            xml.removeSubrange(doctypeRange)
        }
        if let cleanData = xml.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: cleanData, options: [], format: nil) as? [String: Any] {
            return plist
        }
    }
    
    return nil
}

// MARK: - Pattern extraction

struct ExtractedRule {
    let scope: String
    let pattern: String
    let isBlock: Bool  // begin/end pattern vs simple match
}

/// Convert TextMate regex to NSRegularExpression-compatible pattern.
/// TextMate uses Oniguruma/ICU regex syntax which is mostly compatible.
/// Key differences to handle:
/// - \\G anchor → remove (not supported)
/// - (?>...) atomic groups → (?:...) non-capturing (approximate)
/// - \\A, \\Z → ^, $
/// - \\p{...} unicode properties → keep (ICU supports them)
func convertRegex(_ tmRegex: String) -> String {
    var regex = tmRegex
    // Remove \\G anchors
    regex = regex.replacingOccurrences(of: "\\G", with: "")
    // Atomic groups → non-capturing (lossy but functional)
    regex = regex.replacingOccurrences(of: "(?>", with: "(?:")
    return regex
}

func extractRules(from grammar: [String: Any], repository: [String: [String: Any]] = [:]) -> [ExtractedRule] {
    var rules: [ExtractedRule] = []
    let patterns = grammar["patterns"] as? [[String: Any]] ?? []
    
    for pattern in patterns {
        let name = pattern["name"] as? String
        let include = pattern["include"] as? String
        
        // Handle #include references
        if let inc = include {
            if inc.hasPrefix("#"), let refName = inc.dropFirst().components(separatedBy: ".").first {
                let refKey = String(refName)
                if let refPattern = repository[refKey] {
                    rules.append(contentsOf: extractRules(from: refPattern, repository: repository))
                }
            }
            continue
        }
        
        guard let scopeName = name else { continue }
        let mappedScope = mapScope(scopeName)
        
        // begin/end block patterns
        if let begin = pattern["begin"] as? String {
            let end = pattern["end"] as? String ?? ""
            let beginRegex = convertRegex(begin)
            let endRegex = convertRegex(end)
            
            // For begin/end blocks, we create a single-line approximation
            // Full begin/end support requires a stateful engine — we approximate
            // with a greedy match for simple cases
            if !beginRegex.isEmpty && !endRegex.isEmpty {
                let combined = "\(beginRegex)[\\s\\S]*?\(endRegex)"
                rules.append(ExtractedRule(scope: mappedScope, pattern: combined, isBlock: true))
            } else if !beginRegex.isEmpty {
                rules.append(ExtractedRule(scope: mappedScope, pattern: "\(beginRegex).*$", isBlock: false))
            }
        }
        // Match patterns
        else if let match = pattern["match"] as? String {
            let matchRegex = convertRegex(match)
            rules.append(ExtractedRule(scope: mappedScope, pattern: matchRegex, isBlock: false))
        }
        // Nested patterns
        else if pattern["patterns"] != nil {
            rules.append(contentsOf: extractRules(from: pattern, repository: repository))
        }
    }
    
    return rules
}

// MARK: - YAML generation

func generateYAML(from rules: [ExtractedRule], grammarName: String, sourcePath: String) -> String {
    // Deduplicate: keep first occurrence of each (scope, pattern) pair
    var seen = Set<String>()
    var uniqueRules: [ExtractedRule] = []
    for r in rules {
        let key = "\(r.scope)|\(r.pattern)"
        if !seen.contains(key) {
            seen.insert(key)
            uniqueRules.append(r)
        }
    }
    
    // Sort: block patterns first, then longest match first
    uniqueRules.sort { a, b in
        if a.isBlock != b.isBlock { return a.isBlock }
        return a.pattern.count > b.pattern.count
    }
    
    var yaml = ""
    yaml += "# Converted from TextMate grammar: \(grammarName)\n"
    yaml += "# Source: \(sourcePath)\n"
    yaml += "# Auto-generated by TextMateGrammarImporter\n"
    yaml += "# Review and adjust manually — begin/end blocks are approximated.\n"
    yaml += "\n"
    yaml += "rules:\n"
    
    for rule in uniqueRules {
        // Escape backslashes for YAML double-quoted strings
        let escaped = rule.pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
        // Always use double-quoted YAML — safest for regex patterns
        let inner = escaped
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let patternYaml = "\"\(inner)\""
        yaml += "  - scope: \(rule.scope)\n"
        yaml += "    pattern: \(patternYaml)\n"
    }
    
    return yaml
}

// MARK: - CLI

let args = CommandLine.arguments
if args.count < 2 {
    print("Usage: swift TextMateGrammarImporter.swift <path/to/grammar.tmLanguage> [output.yml]")
    print("")
    print("Examples:")
    print("  swift TextMateGrammarImporter.swift ~/Library/Application\\ Support/TextMate/Bundles/Swift.tmbundle/Syntaxes/Swift.tmLanguage")
    print("")
    print("TextMate bundles are at: ~/Library/Application Support/TextMate/Bundles/")
    print("   GitHub: https://github.com/textmate/ — clone any bundle, find Syntaxes/*.tmLanguage")
    exit(1)
}

let inputPath = args[1]

guard let grammar = parseGrammar(inputPath) else {
    print("# Error: Cannot parse grammar file: \(inputPath)")
    print("# Supported formats: JSON (.tmLanguage.json), XML Plist (.tmLanguage), Binary Plist")
    exit(1)
}

let grammarName = (grammar["name"] as? String) ?? grammar["scopeName"] as? String ?? URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
let scopeName = grammar["scopeName"] as? String ?? ""
let repository = grammar["repository"] as? [String: [String: Any]] ?? [:]

let rules = extractRules(from: grammar, repository: repository)
let yaml = generateYAML(from: rules, grammarName: grammarName, sourcePath: inputPath)

if args.count >= 3 {
    try? yaml.write(toFile: args[2], atomically: true, encoding: .utf8)
    print("✅ Grammar written to \(args[2])")
    print("   \(rules.count) rules extracted (scope: \(scopeName))")
} else {
    print(yaml)
    print("\n# ---")
    print("# \(rules.count) rules extracted from: \(grammarName)")
    print("# Scope name: \(scopeName)")
}