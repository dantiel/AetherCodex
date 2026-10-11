import CTreeSitter
import Cocoa
import AetherOracleResources

// MARK: - Tree-Sitter Engine

/// Query-based syntax engine supporting 14 grammars with injection traversal.
final class TreeSitterEngine: SyntaxEngineProtocol {

    // MARK: - Language registry

    private let languageLoaders: [String: () -> UnsafeMutableRawPointer?] = [
        "swift":            { ts_bridge_language_swift() },
        "python":           { ts_bridge_language_python() },
        "javascript":       { ts_bridge_language_javascript() },
        "ruby":             { ts_bridge_language_ruby() },
        "rust":             { ts_bridge_language_rust() },
        "go":               { ts_bridge_language_go() },
        "html":             { ts_bridge_language_html() },
        "css":              { ts_bridge_language_css() },
        "json":             { ts_bridge_language_json() },
        "bash":             { ts_bridge_language_bash() },
        "c":                { ts_bridge_language_c() },
        "php":              { ts_bridge_language_php() },
        "markdown":         { ts_bridge_language_markdown() },
        "markdown_inline":  { ts_bridge_language_markdown_inline() },
    ]

    private var parser: UnsafeMutableRawPointer? = nil
    private var tree: UnsafeMutableRawPointer? = nil
    private var queryLayers: [QueryLayer] = []
    private var primaryLanguagePtr: UnsafeMutableRawPointer? = nil
    private var currentLanguage: (grammar: String, queryName: String)? = nil

    struct QueryLayer {
        let language: String
        let query: UnsafeMutableRawPointer?
    }

    init() {}

    // MARK: - Language

    @discardableResult
    func setLanguage(forExtension ext: String) -> Bool {
        // 1. Try the YAML registry (languages.yml) first — broader coverage
        let registry = SyntaxLoader.loadLanguageRegistry()
        let key = ext.lowercased()
        if let config = registry[key] {
            clearParser()
            queryLayers = []
            guard let langFn = languageLoaders[config.grammar],
                  let langPtr = langFn() else { return false }
            parser = ts_bridge_parser_new()
            ts_bridge_parser_set_language(parser, langPtr)
            primaryLanguagePtr = langPtr
            compileHighlightQuery(grammar: config.grammar, queryName: config.queries[0])
            currentLanguage = (config.grammar, config.queries[0])
            return true
        }
        // 2. Fallback: hardcoded map for common extensions
        let langMap: [String: (String, String)] = [
            "md":       ("markdown", "markdown"),
            "markdown": ("markdown", "markdown"),
            "swift":    ("swift", "swift"),
            "py":       ("python", "python"),
            "js":       ("javascript", "javascript"),
            "mjs":      ("javascript", "javascript"),
            "cjs":      ("javascript", "javascript"),
            "rb":       ("ruby", "ruby"),
            "rs":       ("rust", "rust"),
            "go":       ("go", "go"),
            "html":     ("html", "html"),
            "htm":      ("html", "html"),
            "xml":      ("html", "xml"),
            "css":      ("css", "css"),
            "scss":     ("css", "css"),
            "less":     ("css", "css"),
            "json":     ("json", "json"),
            "sh":       ("bash", "bash"),
            "bash":     ("bash", "bash"),
            "zsh":      ("bash", "bash"),
            "c":        ("c", "c"),
            "h":        ("c", "c"),
            "cpp":      ("c", "c"),
            "cc":       ("c", "c"),
            "cxx":      ("c", "c"),
            "hpp":      ("c", "c"),
            "cs":       ("c", "csharp"),
            "kt":       ("c", "kotlin"),
            "kts":      ("c", "kotlin"),
            "scala":    ("c", "scala"),
            "hs":       ("c", "haskell"),
            "lua":      ("c", "lua"),
            "php":      ("php", "php"),
            "ts":       ("javascript", "typescript"),
            "tsx":      ("javascript", "tsx"),
            "yaml":     ("c", "yaml"),
            "yml":      ("c", "yaml"),
            "toml":     ("c", "toml"),
            "makefile": ("c", "makefile"),
            "mk":       ("c", "makefile"),
        ]
        guard let (grammar, queryName) = langMap[key] else {
            clearParser()
            currentLanguage = nil
            return false
        }
        let ok = loadLanguage(grammar, queryName: queryName)
        if ok { currentLanguage = (grammar, queryName) }
        return ok
    }

    private func loadLanguage(_ grammar: String, queryName: String) -> Bool {
        clearParser()
        queryLayers = []

        guard let langFn = languageLoaders[grammar],
              let langPtr = langFn() else { return false }

        parser = ts_bridge_parser_new()
        ts_bridge_parser_set_language(parser, langPtr)
        primaryLanguagePtr = langPtr

        compileHighlightQuery(grammar: grammar, queryName: queryName)
        return true
    }

    private func compileHighlightQuery(grammar: String, queryName: String) {
        var sources: [String] = []
        if let src = loadQuerySource(name: "\(queryName)_highlights") {
            sources.append(src)
        }
        if grammar == "markdown" || queryName == "markdown" {
            if let inlineSrc = loadQuerySource(name: "markdown_inline_highlights") {
                sources.append(inlineSrc)
            }
        }

        for (idx, source) in sources.enumerated() {
            let queryLang: UnsafeMutableRawPointer?
            if idx == 0 {
                queryLang = primaryLanguagePtr
            } else {
                guard let fn = languageLoaders["markdown_inline"],
                      let ptr = fn() else { continue }
                queryLang = ptr
            }

            guard let lang = queryLang else { continue }

            var errOffset: UInt32 = 0
            var errType: UInt32 = 0
            let q = ts_bridge_query_new(lang, source, UInt32(source.utf8.count),
                                         &errOffset, &errType)
            if q == nil && idx == 0 {
                // Primary query failed (ABI mismatch, syntax error)
                let shortSrc = String(source.prefix(200))
                _ = try? "QUERY_ERROR: errType=\(errType) offset=\(errOffset) src=\(shortSrc)"
                    .write(to: URL(fileURLWithPath: "/tmp/ae_query_err.txt"), atomically: true, encoding: .utf8)
                continue
            }
            guard let query = q else { continue }

            let layerLang = idx == 0 ? grammar : "markdown_inline"
            queryLayers.append(QueryLayer(language: layerLang, query: query))
            
            if idx == 0 {
                let captures = ts_bridge_query_capture_count(query)
                _ = try? "QUERY_OK: grammar=\(grammar) captures=\(captures)"
                    .write(to: URL(fileURLWithPath: "/tmp/ae_query_ok.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    private func loadQuerySource(name: String) -> String? {
        // 1. App bundle (production): Resources/Syntax/queries/
        if let url = Bundle.main.url(forResource: name, withExtension: "scm",
                                      subdirectory: "Syntax/queries") {
            print("[TS] loadQuery bundle: \(url.path)")
            return try? String(contentsOf: url)
        }
        // 2. SPM resource bundle root — query files are flattened here
        if let url = AetherOracleResources.bundle.url(forResource: name, withExtension: "scm",
                                        subdirectory: nil) {
            print("[TS] loadQuery module: \(url.path)")
            return try? String(contentsOf: url)
        }
        // 3. SPM resource bundle with subdirectory (belt and suspenders)
        if let url = AetherOracleResources.bundle.url(forResource: name, withExtension: "scm",
                                        subdirectory: "Syntax/queries") {
            print("[TS] loadQuery module sub: \(url.path)")
            return try? String(contentsOf: url)
        }
        // 4. Dev path relative to project root
        let devPath = "AetherOracle/resources/Syntax/queries/\(name).scm"
        let cwd = FileManager.default.currentDirectoryPath
        print("[TS] loadQuery dev: \(devPath) cwd=\(cwd) exists=\(FileManager.default.fileExists(atPath: devPath))")
        if FileManager.default.fileExists(atPath: devPath) {
            return try? String(contentsOfFile: devPath)
        }
        // 5. Dev path relative to executable (for bundled debug builds)
        if let execURL = Bundle.main.executableURL {
            let adjacent = execURL.deletingLastPathComponent()
                .appendingPathComponent("Syntax/queries/\(name).scm")
            print("[TS] loadQuery exec: \(adjacent.path) exists=\(FileManager.default.fileExists(atPath: adjacent.path))")
            if FileManager.default.fileExists(atPath: adjacent.path) {
                return try? String(contentsOf: adjacent)
            }
        }
        print("[TS] loadQuery: ALL FAILED for \(name)")
        return nil
    }

    // MARK: - Tokenize

    /// Parser resilience: if full re-parse fails (tree-sitter markdown external
    /// scanner can crash on certain constructs), recreate the parser + query and
    /// retry once.  If that still fails, return [] so SyntaxOracle falls back
    /// to the heuristic (regex) engine — which has markdown rules.
    func tokenize(_ text: String, in range: NSRange, proseMode: Bool = false) -> [Token] {
        let nsText = text as NSString
        let length = text.utf8.count
        let cString = nsText.utf8String!

        // Always pass nil for old tree — incremental parsing crashes the markdown
        // external scanner (EXC_BREAKPOINT in serialize / _platform_memmove).
        if let oldTree = tree { ts_bridge_tree_delete(oldTree); tree = nil }

        var treePtr = parser.map { ts_bridge_parser_parse_string($0, nil, cString, UInt32(length)) }

        // ── Retry: recreate parser + query layers on first failure ──
        if treePtr == nil, let lang = currentLanguage {
            NSLog("[TS] tokenize: parse failed, retrying")
            clearParser()
            rebuildForLanguage(lang)
            treePtr = parser.map { ts_bridge_parser_parse_string($0, nil, cString, UInt32(length)) }
        }

        var tokens: [Token] = []

        // Parse succeeded → collect tree-sitter tokens
        if let newTree = treePtr {
            tree = newTree
            if let rootNode = ts_bridge_tree_root_node(newTree) {
                defer { ts_bridge_node_free(rootNode) }
                let byteToUTF16 = buildByteToUTF16(text)

                if let primary = queryLayers.first {
                    collectTokens(layer: primary, root: rootNode,
                                  byteToUTF16: byteToUTF16, range: range, into: &tokens)
                }
                for layer in queryLayers.dropFirst() {
                    collectInjectionTokens(layer: layer, root: rootNode, text: text,
                                           byteToUTF16: byteToUTF16, range: range, into: &tokens)
                }
                collectFencedCodeTokens(root: rootNode, text: text,
                                        byteToUTF16: byteToUTF16, range: range, into: &tokens)
            }
        }

        // ── Heuristics: always run, independent of tree-sitter success ──

        // String interpolation & escape detail (heuristic)
        addStringDetailTokens(in: &tokens, text: text, range: range)

        // Remap identifier tokens for grammar-missing keywords
        remapIdentifierTokens(in: &tokens, text: text, range: range)

        return tokens
    }


    // MARK: - String interpolation & escape heuristic

    /// Two-phase: 1) scan tree-sitter .string tokens for detail,
    /// 2) raw-text scan for interpolated strings tree-sitter missed.
    /// UTF-16 code-unit constants. String-detail scanning indexes by UTF-16
    /// offset (NSRange-aligned). Operating on grapheme clusters (`Array(text)`)
    /// breaks once emoji/surrogate pairs appear: each such grapheme collapses
    /// two UTF-16 units into one, shifting every later index so the closing
    /// quote is missed and the string — and everything after it — loses its
    /// highlight. Code units keep index and NSRange in lockstep.
    private enum U16 {
        static let quote: UInt16 = 0x22      // "
        static let backslash: UInt16 = 0x5C  // \
        static let newline: UInt16 = 0x0A    // \n
        static let lparen: UInt16 = 0x28     // (
        static let rparen: UInt16 = 0x29     // )
        static let lbrace: UInt16 = 0x7B     // {
        static let rbrace: UInt16 = 0x7D     // }
        static let u: UInt16 = 0x75          // u
        static let simpleEscapes: Set<UInt16> = [0x30, 0x74, 0x6E, 0x72, 0x22, 0x27, 0x5C] // 0 t n r " ' \
    }

    private func addStringDetailTokens(in tokens: inout [Token], text: String, range: NSRange) {
        let chars = Array(text.utf16)

        // Phase 1: tree-sitter .string tokens → detail scan only
        let tsStrings = tokens.filter { $0.scope == .string }
        for tsStr in tsStrings {
            let loc = tsStr.range.location
            let end = tsStr.range.location + tsStr.range.length
            let contentStart: Int
            let contentEnd: Int
            if loc < chars.count, end <= chars.count, end - loc >= 2,
               chars[loc] == U16.quote, chars[end - 1] == U16.quote {
                contentStart = loc + 1
                contentEnd = end - 1
            } else if loc + 2 < chars.count, end <= chars.count, end - loc >= 6,
                      chars[loc] == U16.quote, chars[loc+1] == U16.quote, chars[loc+2] == U16.quote,
                      chars[end-3] == U16.quote, chars[end-2] == U16.quote, chars[end-1] == U16.quote {
                contentStart = loc + 3
                contentEnd = end - 3
            } else {
                contentStart = loc
                contentEnd = end
            }
            if contentEnd > contentStart {
                processStringContent(chars: chars, baseLoc: contentStart,
                                     contentStart: contentStart, contentEnd: contentEnd,
                                     into: &tokens, emitStringGaps: false)
            }
        }

        // Phase 2: raw-text scan for interpolated strings without coverage
        let covered = tsStrings.map { NSRange(location: $0.range.location,
                                               length: $0.range.length) }
        func isCovered(_ loc: Int) -> Bool {
            covered.contains { $0.location <= loc && loc < $0.location + $0.length }
        }

        var i = range.location
        let end = range.upperBound

        while i < end {
            guard i < chars.count else { break }
            guard !isCovered(i) else { i += 1; continue }

            // Check for """ (multiline)
            if i + 2 < chars.count, chars[i] == U16.quote, chars[i+1] == U16.quote, chars[i+2] == U16.quote {
                let strStart = i
                i += 3
                while i + 2 < chars.count {
                    if chars[i] == U16.quote, chars[i+1] == U16.quote, chars[i+2] == U16.quote {
                        tokens.append(Token(range: NSRange(location: strStart, length: 3),
                                            scope: .string))
                        let hasDetail = stringHasDetailContent(chars: chars,
                                                                start: strStart + 3, end: i)
                        processStringContent(chars: chars, baseLoc: strStart + 3,
                                             contentStart: strStart + 3, contentEnd: i,
                                             into: &tokens, emitStringGaps: hasDetail)
                        if !hasDetail {
                            tokens.append(Token(
                                range: NSRange(location: strStart + 3, length: i - (strStart + 3)),
                                scope: .string))
                        }
                        tokens.append(Token(range: NSRange(location: i, length: 3),
                                            scope: .string))
                        i += 3
                        break
                    }
                    i += 1
                }
                continue
            }

            // Check for " (single-line)
            if chars[i] == U16.quote {
                if i + 2 < chars.count, chars[i+1] == U16.quote, chars[i+2] == U16.quote {
                    i += 1; continue
                }
                let strStart = i
                i += 1
                while i < chars.count {
                    if chars[i] == U16.backslash { i += 2; continue }
                    if chars[i] == U16.quote {
                        tokens.append(Token(range: NSRange(location: strStart, length: 1),
                                            scope: .string))
                        let hasDetail = stringHasDetailContent(chars: chars,
                                                                start: strStart + 1, end: i)
                        processStringContent(chars: chars, baseLoc: strStart + 1,
                                             contentStart: strStart + 1, contentEnd: i,
                                             into: &tokens, emitStringGaps: hasDetail)
                        if !hasDetail {
                            tokens.append(Token(
                                range: NSRange(location: strStart + 1, length: i - (strStart + 1)),
                                scope: .string))
                        }
                        tokens.append(Token(range: NSRange(location: i, length: 1),
                                            scope: .string))
                        i += 1
                        break
                    }
                    if chars[i] == U16.newline { break }
                    i += 1
                }
                continue
            }

            i += 1
        }
    }

    /// Returns true if the string literal content contains detail that
    /// our heuristic should process: \\( interpolation, \\n/\\t/\\r escapes,
    /// \\u{…} unicode escapes, or \\\" / \\' / \\\\ / \\0 escapes.
    private func stringHasDetailContent(chars: [UInt16],
                                         start: Int, end: Int) -> Bool {
        var j = start
        while j + 1 < end {
            guard chars[j] == U16.backslash else { j += 1; continue }
            let next = chars[j + 1]
            if next == U16.lparen { return true }           // \\( … interpolation
            if U16.simpleEscapes.contains(next) { return true } // \0 \t \n \r \" \' \\
            if next == U16.u { return true }            // \u{…} unicode
            j += 2
        }
        return false
    }

    private func processStringContent(chars: [UInt16], baseLoc: Int,
                                       contentStart: Int, contentEnd: Int,
                                       into tokens: inout [Token],
                                       emitStringGaps: Bool = true) {
        var i = contentStart
        var plainStart = contentStart

        func flushPlain(_ end: Int) {
            guard emitStringGaps else { plainStart = end; return }
            let len = end - plainStart
            if len > 0 {
                tokens.append(Token(
                    range: NSRange(location: plainStart, length: len),
                    scope: .string))
            }
        }

        while i < contentEnd {
            guard i < chars.count else { break }
            guard chars[i] == U16.backslash else { i += 1; continue }
            guard i + 1 < chars.count else { break }

            let next = chars[i + 1]

            if next == U16.lparen {
                flushPlain(i)
                tokens.append(Token(
                    range: NSRange(location: i, length: 2),
                    scope: .metaEmbedded))

                var depth = 1
                var j = i + 2
                while j < contentEnd, depth > 0 {
                    if chars[j] == U16.lparen  { depth += 1 }
                    else if chars[j] == U16.rparen { depth -= 1 }
                    j += 1
                }
                let innerLen = j - 1 - (i + 2)
                if innerLen > 0 {
                    tokens.append(Token(
                        range: NSRange(location: i + 2, length: innerLen),
                        scope: .metaEmbedded))
                }
                tokens.append(Token(
                    range: NSRange(location: j - 1, length: 1),
                    scope: .metaEmbedded))

                i = j
                plainStart = i
            } else if U16.simpleEscapes.contains(next) {
                flushPlain(i)
                tokens.append(Token(
                    range: NSRange(location: i, length: 2),
                    scope: .constantCharacterEscape))
                i += 2
                plainStart = i
            } else if next == U16.u, i + 2 < contentEnd, chars[i + 2] == U16.lbrace {
                flushPlain(i)
                var j = i + 3
                while j < contentEnd, chars[j] != U16.rbrace { j += 1 }
                if j < contentEnd { j += 1 }
                tokens.append(Token(
                    range: NSRange(location: i, length: j - i),
                    scope: .constantCharacterEscape))
                i = j
                plainStart = i
            } else {
                i += 2
            }
        }
        flushPlain(contentEnd)
    }

    // MARK: - Identifier remapping

    /// Keywords like `where`, `try`, `await`, `override`, `some`, `any`, etc. are NOT
    /// anonymous tokens in the ABI 14 grammar — they parse as bare `(identifier)` nodes.
    /// This pass remaps their `.variable` scope to the correct keyword/storage scope.
    /// Also remaps `self`/`super` → `.variableLanguage` and `Self` → `.entityNameType`,
    /// support functions → `.functionSupport`, call-site identifiers → `.variableFunction`,
    /// member-access fields → `.variableInstance`, call parameters → `.variableParameter`.
    private func remapIdentifierTokens(in tokens: inout [Token], text: String, range: NSRange) {
        let nsText = text as NSString

        // Keywords that should always be .keyword
        let keywordSet: Set<String> = [
            "where", "try", "await", "fallthrough",
            "some", "any", "get", "set", "willSet", "didSet",
            "precedencegroup", "associativity", "left", "right", "none",
            "actor", "nonisolated", "isolated", "async",
        ]

        // Modifier keywords → .storage (grey-blue, bold)
        let modifierSet: Set<String> = [
            "override", "lazy", "weak", "unowned",
            "mutating", "nonmutating", "convenience", "required", "optional",
            "dynamic", "final", "indirect",
        ]

        // Support functions → .functionSupport (light purple)
        let supportFunctionSet: Set<String> = [
            "print", "dump", "debugPrint", "fatalError",
            "precondition", "preconditionFailure", "assert", "assertionFailure",
            "max", "min", "abs", "zip", "stride",
        ]

        /// Returns the first non-whitespace character before `loc` (scanning backwards).
        func prevNonSpace(_ loc: Int) -> String? {
            var ci = loc - 1
            while ci >= 0 {
                let c = nsText.substring(with: NSRange(location: ci, length: 1))
                if c != " " && c != "\t" && c != "\n" { return c }
                ci -= 1
            }
            return nil
        }

        for i in tokens.indices {
            let t = tokens[i]
            guard t.scope == .variable || t.scope == .variableOther else { continue }
            guard t.range.location >= range.location,
                  t.range.upperBound <= range.upperBound else { continue }

            let word = nsText.substring(with: t.range)
            let charAfter = t.range.upperBound < nsText.length
                ? nsText.substring(with: NSRange(location: t.range.upperBound, length: 1)) : nil
            let charBefore = t.range.location > 0
                ? nsText.substring(with: NSRange(location: t.range.location - 1, length: 1)) : nil
            let prevChar = prevNonSpace(t.range.location)

            if keywordSet.contains(word) {
                tokens[i].scope = .keyword
            } else if modifierSet.contains(word) {
                tokens[i].scope = .storage
            } else if supportFunctionSet.contains(word) {
                tokens[i].scope = .functionSupport
            } else if word == "self" || word == "super" {
                tokens[i].scope = .variableLanguage
            } else if word == "Self" {
                tokens[i].scope = .entityNameType
            } else if charAfter == "(" {
                // Function/method call site → italic
                tokens[i].scope = .variableFunction
            } else if charBefore == "." {
                // Member access field → peach (yellow)
                tokens[i].scope = .variableInstance
            } else if prevChar == "(" || prevChar == "," {
                // Call parameter → italic
                tokens[i].scope = .variableParameter
            }
        }
    }

    // MARK: - Primary layer collection

    private func collectTokens(layer: QueryLayer, root: UnsafeMutableRawPointer,
                                byteToUTF16: [Int], range: NSRange,
                                into tokens: inout [Token]) {
        guard let cursor = ts_bridge_query_cursor_new() else { return }
        defer { ts_bridge_query_cursor_delete(cursor) }

        ts_bridge_query_cursor_exec(cursor, layer.query, root)

        var matchId: UInt32 = 0
        var captureIdx: UInt32 = 0
        var nodeOut: UnsafeMutableRawPointer? = nil

        while ts_bridge_query_cursor_next_capture(cursor, &matchId, &captureIdx, &nodeOut) {
            guard let node = nodeOut else { continue }

            var capNameLen: UInt32 = 0
            guard let capNamePtr = ts_bridge_query_capture_name_for_id(layer.query, captureIdx,
                                                                        &capNameLen) else {
                ts_bridge_node_free(node)
                continue
            }
            let capNameStr = String(cString: capNamePtr)

            guard let scope = CaptureScopeMapper.scope(for: capNameStr) else {
                ts_bridge_node_free(node)
                continue
            }

            let startByte = Int(ts_bridge_node_start_byte(node))
            let endByte = Int(ts_bridge_node_end_byte(node))
            ts_bridge_node_free(node)

            let startUTF16 = byteToUTF16[safe: startByte] ?? 0
            let endUTF16 = byteToUTF16[safe: endByte] ?? startUTF16
            let len = endUTF16 - startUTF16

            guard len > 0 else { continue }
            let r = NSRange(location: startUTF16, length: len)
            guard r.location >= range.location,
                  r.upperBound <= range.upperBound else { continue }

            tokens.append(Token(range: r, scope: scope))
        }
    }

    // MARK: - Injection traversal

    private func collectInjectionTokens(layer: QueryLayer, root: UnsafeMutableRawPointer,
                                         text: String, byteToUTF16: [Int],
                                         range: NSRange, into tokens: inout [Token]) {
        var inlineNodes: [(startByte: Int, endByte: Int)] = []
        let targets: Set<String> = ["inline", "heading_content"]
        collectInjectionWalk(root, targetTypes: targets, results: &inlineNodes)

        // Anchor NSString once to keep utf8String alive across inner parse
        let nsText = text as NSString

        for node in inlineNodes {
            let nodeStart = node.startByte
            let nodeEnd = node.endByte
            guard nodeEnd > nodeStart else { continue }

            // Convert byte offsets → UTF-16 offsets for NSString substring
            let nodeStartUTF16 = byteToUTF16[safe: nodeStart] ?? 0
            let nodeEndUTF16 = byteToUTF16[safe: nodeEnd] ?? nodeStartUTF16
            guard nodeEndUTF16 > nodeStartUTF16 else { continue }

            let inlineText = nsText.substring(
                with: NSRange(location: nodeStartUTF16, length: nodeEndUTF16 - nodeStartUTF16))

            guard let inlineFn = languageLoaders["markdown_inline"],
                  let inlineLang = inlineFn() else { continue }

            let inlineParser = ts_bridge_parser_new()
            ts_bridge_parser_set_language(inlineParser, inlineLang)

            // Anchor inline NSString so utf8String stays alive during parse
            let inlineNs = inlineText as NSString
            let inlineCStr = inlineNs.utf8String!
            let inlineLen = inlineText.utf8.count
            let inlineTreePtr = ts_bridge_parser_parse_string(inlineParser, nil, inlineCStr, UInt32(inlineLen))

            guard let inlineTree = inlineTreePtr,
                  let inlineRoot = ts_bridge_tree_root_node(inlineTree) else {
                ts_bridge_parser_delete(inlineParser)
                continue
            }

            guard let ic = ts_bridge_query_cursor_new() else {
                ts_bridge_node_free(inlineRoot)
                ts_bridge_tree_delete(inlineTree)
                ts_bridge_parser_delete(inlineParser)
                continue
            }

            ts_bridge_query_cursor_exec(ic, layer.query, inlineRoot)

            var matchId: UInt32 = 0
            var captureIdx: UInt32 = 0
            var nodeOut: UnsafeMutableRawPointer? = nil

            while ts_bridge_query_cursor_next_capture(ic, &matchId, &captureIdx, &nodeOut) {
                guard let capNode = nodeOut else { continue }

                var capNameLen: UInt32 = 0
                guard let capNamePtr = ts_bridge_query_capture_name_for_id(layer.query, captureIdx,
                                                                            &capNameLen) else {
                    ts_bridge_node_free(capNode)
                    continue
                }
                let capNameStr = String(cString: capNamePtr)

                guard let scope = CaptureScopeMapper.scope(for: capNameStr) else {
                    ts_bridge_node_free(capNode)
                    continue
                }

                let innerStart = Int(ts_bridge_node_start_byte(capNode))
                let innerEnd = Int(ts_bridge_node_end_byte(capNode))
                ts_bridge_node_free(capNode)

                let globalStart = nodeStart + innerStart
                let globalEnd = nodeStart + innerEnd

                let startUTF16 = byteToUTF16[safe: globalStart] ?? 0
                let endUTF16 = byteToUTF16[safe: globalEnd] ?? startUTF16
                let len = endUTF16 - startUTF16

                guard len > 0 else { continue }
                let r = NSRange(location: startUTF16, length: len)
                guard r.location >= range.location,
                      r.upperBound <= range.upperBound else { continue }

                tokens.append(Token(range: r, scope: scope))
            }

            ts_bridge_query_cursor_delete(ic)
            ts_bridge_node_free(inlineRoot)
            ts_bridge_tree_delete(inlineTree)
            ts_bridge_parser_delete(inlineParser)
        }
    }

    private func collectInjectionWalk(_ node: UnsafeMutableRawPointer,
                                       targetTypes: Set<String>,
                                       results: inout [(startByte: Int, endByte: Int)]) {
        guard let typePtr = ts_bridge_node_type(node) else { return }
        let typeStr = String(cString: typePtr)

        if targetTypes.contains(typeStr) {
            let start = Int(ts_bridge_node_start_byte(node))
            let end = Int(ts_bridge_node_end_byte(node))
            results.append((start, end))
        }

        let childCount = ts_bridge_node_child_count(node)
        for i in 0..<childCount {
            guard let child = ts_bridge_node_child(node, i) else { continue }
            collectInjectionWalk(child, targetTypes: targetTypes, results: &results)
            ts_bridge_node_free(child)
        }
    }

    // MARK: - Embedded syntax (fenced code blocks)

    /// Info-string → language-loader key for fenced code blocks.
    private func resolveEmbeddedLanguage(_ info: String) -> String? {
        let map: [String: String] = [
            "swift": "swift", "python": "python", "py": "python",
            "javascript": "javascript", "js": "javascript",
            "typescript": "javascript", "ts": "javascript",  // fallback to JS grammar
            "ruby": "ruby", "rb": "ruby",
            "rust": "rust", "rs": "rust",
            "go": "go", "golang": "go",
            "html": "html", "htm": "html",
            "css": "css", "scss": "css", "less": "css",
            "json": "json",
            "bash": "bash", "sh": "bash", "zsh": "bash", "shell": "bash",
            "c": "c", "cpp": "c", "c++": "c", "cc": "c", "cxx": "c", "h": "c", "hpp": "c",
            "php": "php",
            "java": "java", "kotlin": "java", "kt": "java",
        ]
        let firstWord = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return map[firstWord.lowercased()]
    }

    private func collectFencedCodeTokens(root: UnsafeMutableRawPointer,
                                          text: String, byteToUTF16: [Int],
                                          range: NSRange, into tokens: inout [Token]) {
        var blocks: [(contentStartByte: Int, contentEndByte: Int, infoStartByte: Int, infoEndByte: Int)] = []
        collectFencedBlockWalk(root, results: &blocks)
        guard !blocks.isEmpty else { return }

        let nsText = text as NSString

        for block in blocks {
            let infoStartUTF16 = byteToUTF16[safe: block.infoStartByte] ?? 0
            let infoEndUTF16 = byteToUTF16[safe: block.infoEndByte] ?? infoStartUTF16
            guard infoEndUTF16 > infoStartUTF16 else { continue }
            let infoStr = nsText.substring(
                with: NSRange(location: infoStartUTF16, length: infoEndUTF16 - infoStartUTF16))
            guard let langKey = resolveEmbeddedLanguage(infoStr) else { continue }

            let contentStartUTF16 = byteToUTF16[safe: block.contentStartByte] ?? 0
            let contentEndUTF16 = byteToUTF16[safe: block.contentEndByte] ?? contentStartUTF16
            guard contentEndUTF16 > contentStartUTF16 else { continue }
            let contentText = nsText.substring(
                with: NSRange(location: contentStartUTF16, length: contentEndUTF16 - contentStartUTF16))

            tokens.append(contentsOf: tokenizeEmbeddedBlock(content: contentText,
                                                            language: langKey,
                                                            baseUTF16: contentStartUTF16,
                                                            range: range))
        }
    }

    /// Tokenize a fenced-code-block's content with its embedded language,
    /// returning tokens in document UTF-16 coordinates (offset by `baseUTF16`).
    private func tokenizeEmbeddedBlock(content: String, language langKey: String,
                                       baseUTF16: Int, range: NSRange) -> [Token] {
        guard let langFn = languageLoaders[langKey], let langPtr = langFn() else { return [] }

        let embParser = ts_bridge_parser_new()
        ts_bridge_parser_set_language(embParser, langPtr)
        let embNs = content as NSString
        let embCStr = embNs.utf8String!
        let embTreePtr = ts_bridge_parser_parse_string(embParser, nil, embCStr,
                                                       UInt32(content.utf8.count))
        guard let embTree = embTreePtr,
              let embRoot = ts_bridge_tree_root_node(embTree) else {
            ts_bridge_parser_delete(embParser)
            return []
        }
        defer {
            ts_bridge_node_free(embRoot)
            ts_bridge_tree_delete(embTree)
            ts_bridge_parser_delete(embParser)
        }

        guard let querySrc = loadQuerySource(name: "\(langKey)_highlights") else { return [] }
        var errOffset: UInt32 = 0
        var errType: UInt32 = 0
        guard let query = ts_bridge_query_new(langPtr, querySrc,
                                               UInt32(querySrc.utf8.count),
                                               &errOffset, &errType) else { return [] }
        defer { ts_bridge_query_delete(query) }
        guard let qc = ts_bridge_query_cursor_new() else { return [] }
        defer { ts_bridge_query_cursor_delete(qc) }

        ts_bridge_query_cursor_exec(qc, query, embRoot)
        let contentByteToUTF16 = buildByteToUTF16(content)

        var tokens: [Token] = []
        var matchId: UInt32 = 0
        var captureIdx: UInt32 = 0
        var nodeOut: UnsafeMutableRawPointer? = nil

        while ts_bridge_query_cursor_next_capture(qc, &matchId, &captureIdx, &nodeOut) {
            guard let capNode = nodeOut else { continue }

            var capNameLen: UInt32 = 0
            guard let capNamePtr = ts_bridge_query_capture_name_for_id(query, captureIdx,
                                                                        &capNameLen) else {
                ts_bridge_node_free(capNode)
                continue
            }
            let capNameStr = String(cString: capNamePtr)
            guard let scope = CaptureScopeMapper.scope(for: capNameStr) else {
                ts_bridge_node_free(capNode)
                continue
            }

            let innerStart = Int(ts_bridge_node_start_byte(capNode))
            let innerEnd = Int(ts_bridge_node_end_byte(capNode))
            ts_bridge_node_free(capNode)

            let startUTF16 = baseUTF16 + (contentByteToUTF16[safe: innerStart] ?? 0)
            let endUTF16 = baseUTF16 + (contentByteToUTF16[safe: innerEnd] ?? (contentByteToUTF16[safe: innerStart] ?? 0))
            let len = endUTF16 - startUTF16

            guard len > 0 else { continue }
            let r = NSRange(location: startUTF16, length: len)
            guard r.location >= range.location,
                  r.upperBound <= range.upperBound else { continue }

            tokens.append(Token(range: r, scope: scope))
        }
        return tokens
    }

    /// Regex-driven fenced-code-block highlighting for the heuristic markdown
    /// path (which bypasses tree-sitter's unreliable markdown parser). Finds
    /// ```lang / ~~~lang blocks, resolves the language, and tokenizes content.
    func tokenizeFencedCodeBlocks(in text: String, range: NSRange) -> [Token] {
        let nsText = text as NSString
        guard let re = try? NSRegularExpression(
            pattern: "(?m)^(`{3,}|~{3,})[ \\t]*([^\\n]*)\\n([\\s\\S]*?)^\\1[ \\t]*$",
            options: []
        ) else { return [] }

        var tokens: [Token] = []
        let full = NSRange(location: 0, length: nsText.length)
        re.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
            guard let m = m, m.numberOfRanges >= 4 else { return }
            let info = nsText.substring(with: m.range(at: 2))
            guard let langKey = self.resolveEmbeddedLanguage(info) else { return }
            let contentRange = m.range(at: 3)
            guard contentRange.length > 0 else { return }
            let content = nsText.substring(with: contentRange)
            tokens.append(contentsOf: self.tokenizeEmbeddedBlock(content: content,
                                                                 language: langKey,
                                                                 baseUTF16: contentRange.location,
                                                                 range: range))
        }
        return tokens
    }
    private func collectFencedBlockWalk(_ node: UnsafeMutableRawPointer,
                                         results: inout [(contentStartByte: Int, contentEndByte: Int,
                                                          infoStartByte: Int, infoEndByte: Int)]) {
        guard let typePtr = ts_bridge_node_type(node) else { return }
        let typeStr = String(cString: typePtr)

        if typeStr == "fenced_code_block" {
            var infoStart: Int?, infoEnd: Int?, contentStart: Int?, contentEnd: Int?
            let childCount = ts_bridge_node_child_count(node)
            for i in 0..<childCount {
                guard let child = ts_bridge_node_child(node, i) else { continue }
                defer { ts_bridge_node_free(child) }
                guard let ctPtr = ts_bridge_node_type(child) else { continue }
                let ct = String(cString: ctPtr)
                if ct == "info_string" {
                    infoStart = Int(ts_bridge_node_start_byte(child))
                    infoEnd = Int(ts_bridge_node_end_byte(child))
                } else if ct == "code_fence_content" {
                    contentStart = Int(ts_bridge_node_start_byte(child))
                    contentEnd = Int(ts_bridge_node_end_byte(child))
                }
            }
            if let istart = infoStart, let iend = infoEnd, let cs = contentStart, let ce = contentEnd {
                results.append((contentStartByte: cs, contentEndByte: ce,
                                infoStartByte: istart, infoEndByte: iend))
            }
            return // don't recurse into children of fenced_code_block
        }

        let childCount = ts_bridge_node_child_count(node)
        for i in 0..<childCount {
            guard let child = ts_bridge_node_child(node, i) else { continue }
            collectFencedBlockWalk(child, results: &results)
            ts_bridge_node_free(child)
        }
    }

    // MARK: - Byte → UTF-16

    private func buildByteToUTF16(_ text: String) -> [Int] {
        var map: [Int] = []
        var utf16Idx = 0
        for scalar in text.unicodeScalars {
            let byteCount = scalar.utf8.count
            for _ in 0..<byteCount {
                map.append(utf16Idx)
            }
            utf16Idx += (scalar.value > 0xFFFF ? 2 : 1)
        }
        map.append(utf16Idx)
        return map
    }

    // MARK: - Cleanup

    private func clearParser() {
        if let t = tree { ts_bridge_tree_delete(t); tree = nil }
        if let p = parser { ts_bridge_parser_delete(p); parser = nil }
        for layer in queryLayers {
            if let q = layer.query { ts_bridge_query_delete(q) }
        }
        queryLayers = []
        currentLanguage = nil
    }

    /// Rebuild parser + query layers from stored language info (for retry on parse failure).
    private func rebuildForLanguage(_ lang: (grammar: String, queryName: String)) {
        guard let langFn = languageLoaders[lang.grammar],
              let langPtr = langFn() else { return }
        parser = ts_bridge_parser_new()
        ts_bridge_parser_set_language(parser, langPtr)
        primaryLanguagePtr = langPtr
        compileHighlightQuery(grammar: lang.grammar, queryName: lang.queryName)
        currentLanguage = lang
    }

    deinit { clearParser() }
}

// MARK: - Capture → TokenScope mapper

private enum CaptureScopeMapper {
    static func scope(for name: String) -> TokenScope? {
        switch name {
        // ── Markdown ──
        case "text.title.1":                return .heading1
        case "text.title.2":                return .heading2
        case "text.title.3":                return .heading3
        case "text.title.4":                return .heading4
        case "text.title.5":                return .heading5
        case "text.title.6":                return .heading6
        case "text.title":                  return .heading1
        case "text.emphasis":               return .emphasis
        case "text.strong":                 return .strong
        case "text.strikethrough":          return .strikethrough
        case "text.quote":                  return .blockquote
        case "text.rule":                   return .thematicBreak
        case "markup.raw.block":            return .codeBlock
        case "markup.raw.inline":           return .inlineCode
        case "markup.list.checked":         return .checkedListItem
        case "text.uri":                    return .string
        case "text.reference":              return .variable
        case "punctuation.delimiter":       return .punctuation
        case "punctuation.table":           return .punctuation
        case "text.table.header":           return .strong
        case "string.escape":               return .stringEscape
        // ── Swift / General ──
        case "type":                        return .entityNameType
        case "typeBuiltin":                 return .typeSupport
        case "constructor":                 return .entityNameFunction
        case "boolean":                     return .constantLanguage
        case "operator":                    return .operator
        case "punctuationBracket":          return .punctuation
        case "constantBuiltin":             return .constantSupport
        case "label":                       return .tag
        case "characterSpecial":            return .constantCharacter
        case "supportFunction":             return .functionSupport
        // ── Keyword sub-scopes (explicit — before prefix fallback) ──
        case "keywordType":                 return .storageType
        case "keywordModifier":             return .storage
        case "keywordDirective":            return .preprocessor
        case "keywordReturn":               return .keyword
        case "keywordRepeat":               return .keyword
        case "keywordConditional":          return .keyword
        case "keywordFunction":             return .keyword
        case "keywordImport":               return .keyword
        // ── Function / Variable sub-scopes ──
        case "functionMethod":              return .entityNameFunction
        case "variableParameter":           return .variableParameter
        case "variableOther":               return .variableOther
        case "variableOtherMember":         return .variableOther
        // ── Prefix fallbacks ──
        default:
            if name.hasPrefix("keyword")    { return .keyword }
            if name.hasPrefix("comment")    { return .comment }
            if name.hasPrefix("string")     { return .string }
            if name.hasPrefix("number")     { return .number }
            if name.hasPrefix("text.title") { return .heading1 }
            if name.hasPrefix("function")   { return .entityNameFunction }
            if name.hasPrefix("variable")   { return .variable }
            if name.hasPrefix("attribute")  { return .variable }
            if name.hasPrefix("type")       { return .entityNameType }
            if name.hasPrefix("operator")   { return .operator }
            if name.hasPrefix("punctuation") { return .punctuation }
            if name.hasPrefix("boolean")    { return .constantLanguage }
            if name.hasPrefix("constant")   { return .constant }
            if name.hasPrefix("entity")     { return .entityNameType }
            if name.hasPrefix("storage")    { return .storage }
            return nil
        }
    }
}

// MARK: - Safe array access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}