import Cocoa

// MARK: - Syntax Engine Protocol

protocol SyntaxEngineProtocol {
    func tokenize(_ text: String, in range: NSRange, proseMode: Bool) -> [Token]
}

// MARK: - Token

struct Token {
    let range: NSRange
    var scope: TokenScope
}

// MARK: - Heuristic Syntax Engine

/// Fallback regex-based tokenizer. Applied longest-pattern-first.
/// Supports prose mode: when true, code-only rules (keyword, type, operator, etc.) are
/// skipped to avoid spurious highlighting of prose (e.g. capitalized words as .type).
final class HeuristicSyntaxEngine: SyntaxEngineProtocol {

    private struct Rule {
        let scope: TokenScope
        let pattern: NSRegularExpression
    }

    private let allRules: [Rule]
    /// Rules safe for prose (markdown, text). Excludes code-specific patterns.
    private let proseRules: [Rule]
    /// Rules safe for code — excludes markup-only scopes (headings, emphasis,
    /// blockquotes) so `#` in YAML/Ruby/shell reads as a comment, never a heading.
    private let codeRules: [Rule]

    /// Prose-safe scopes — only these rules apply to markdown/text files.
    private static let proseScopes: Set<TokenScope> = [
        .codeBlock, .inlineCode,
        .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
        .blockquote, .thematicBreak,
        .strong, .emphasis, .strikethrough,
        .link, .linkURL,
        .punctuation,
    ]

    /// Markup-only scopes that must never fire in code files.
    private static let markupOnlyScopes: Set<TokenScope> = [
        .codeBlock, .inlineCode,
        .heading, .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
        .blockquote, .thematicBreak,
        .strong, .emphasis, .strikethrough,
        .link, .linkURL,
        .checkedListItem, .markup, .markupRaw, .markupOther,
    ]

    init() {
        let specs = SyntaxLoader.loadHeuristicRules()
        let compiled: [Rule] = specs.compactMap { spec in
            guard let re = try? NSRegularExpression(
                pattern: spec.pattern, options: [.anchorsMatchLines]
            ) else { return nil }
            return Rule(scope: spec.scope, pattern: re)
        }
        allRules = compiled
        proseRules = compiled.filter { Self.proseScopes.contains($0.scope) }
        codeRules = compiled.filter { !Self.markupOnlyScopes.contains($0.scope) }
    }

    /// - Parameter proseMode: When true, only prose-safe rules are applied
    ///   (prevents code-only patterns like .type/.keyword from firing on markdown).
    func tokenize(_ text: String, in range: NSRange, proseMode: Bool = false) -> [Token] {
        let rules = proseMode ? proseRules : codeRules
        var tokens: [Token] = []
        var covered = IndexSet()

        for rule in rules.sorted(by: { $0.pattern.pattern.count > $1.pattern.pattern.count }) {
            let matches = rule.pattern.matches(in: text, options: [], range: range)
            for m in matches {
                let r = m.range
                let rangeExpr = r.location..<(r.location + r.length)
                guard r.length > 0, !covered.contains(integersIn: rangeExpr) else { continue }
                tokens.append(Token(range: r, scope: rule.scope))
                covered.insert(integersIn: rangeExpr)
            }
        }

        var pos = range.location
        let end = range.location + range.length
        while pos < end {
            if let gap = covered.integerGreaterThanOrEqualTo(pos), gap > pos {
                tokens.append(Token(range: NSRange(location: pos, length: gap - pos), scope: .plain))
                pos = gap
            } else if covered.contains(pos) {
                pos += 1
            } else {
                let rest = end - pos
                tokens.append(Token(range: NSRange(location: pos, length: rest), scope: .plain))
                break
            }
        }

        return tokens.sorted { $0.range.location < $1.range.location }
    }
}

// MARK: - Singleton

final class SyntaxOracle {
    static let shared = SyntaxOracle()

    private var treeSitterEngine = TreeSitterEngine()
    private let heuristicEngine = HeuristicSyntaxEngine()

    /// Clean base font + size from applyThemeChrome — used when font param is nil,
    /// and for multiplier math. Never reflects textView.font (polluted by tokens).
    var baseFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Current file extension (lowercased), set by openFile.  Used to decide
    /// prose mode (markdown/text) for the heuristic fallback engine.
    private(set) var currentExtension: String = ""

    private init() {}

    /// Set the language for tree-sitter based on file extension.
    /// For unsupported languages, clears the parser so heuristic tokenizer takes over.
    func setLanguage(forExtension ext: String) {
        let aliases = ["jsx": "js", "mts": "ts", "cts": "ts", "xhtml": "html", "pyw": "py"]
        treeSitterEngine.setLanguage(forExtension: aliases[ext.lowercased()] ?? ext)
        currentExtension = ext.lowercased()
    }

    /// Whether the current file is prose (markdown / text) — heuristic should skip code rules.
    private var isProse: Bool {
        let proseExts: Set<String> = ["md", "markdown", "mkdn", "mdown", "txt", "text"]
        return proseExts.contains(currentExtension)
    }

    /// Extensions with no tree-sitter grammar — heuristic engine exclusively.
    private var isHeuristicOnly: Bool {
        let exts: Set<String> = ["chaml", "coffeehaml"]
        return exts.contains(currentExtension)
    }

    /// Returns tokens at a specific UTF-16 character position (for scope inspector).
    func tokensAt(position: Int, in text: String) -> [Token] {
        let tokens = tokenize(text)
        return tokens.filter { NSLocationInRange(position, $0.range) }
    }

    /// Tokenize full document. Tree-sitter is preferred for structure + embedded syntax.
    /// When tree-sitter produces few/no tokens (parser crash, ABI mismatch), fall back
    /// to the heuristic engine for all scopes. For prose, the heuristic supplements
    /// inline styles (bold, italic) that markdown_inline injection silently drops.
    func tokenize(_ text: String, range: NSRange? = nil) -> [Token] {
        let r = range ?? NSRange(location: 0, length: (text as NSString).length)
        // Prose files (markdown, text): use heuristic engine exclusively.
        // Tree-sitter's markdown parser is unreliable (external scanner crashes,
        // silent inline injection failures, error-recovery artifacts). The
        // heuristic engine handles all markdown constructs with deterministic
        // regex patterns — headings, code blocks, blockquotes, bold, italic,
        // strikethrough, inline code, links, lists, thematic breaks.
        var tokens: [Token]
        if TemplateSyntaxEngine.extensions.contains(currentExtension) {
            tokens = TemplateSyntaxEngine.tokenize(text, extension: currentExtension, range: r)
        } else if isProse {
            tokens = heuristicEngine.tokenize(text, in: r, proseMode: true)
            // Fenced code blocks with a language get real syntax highlighting
            // from the tree-sitter engine, overlaid on the heuristic .codeBlock
            // base (monospace + background). Deterministic regex bounds; no
            // reliance on the markdown tree-sitter parser.
            tokens += treeSitterEngine.tokenizeFencedCodeBlocks(in: text, range: r)
        } else if isHeuristicOnly {
            tokens = heuristicEngine.tokenize(text, in: r, proseMode: false)
        } else {
            let tsTokens = treeSitterEngine.tokenize(text, in: r)
            if tsTokens.count <= 3 {
                // Tree-sitter failed for a code file — parser crash, ABI mismatch,
                // or query syntax error. Fall back to heuristic for everything.
                tokens = heuristicEngine.tokenize(text, in: r, proseMode: false)
            } else {
                // Tree-sitter succeeds but the grammar has gaps — keywords like
                // `where` and `fallthrough` aren't grammar tokens in ABI 14.
                // Supplement with targeted heuristic tokens (keywords, booleans,
                // nil). applyHighlighting dedup keeps tree-sitter for overlaps.
                let hTokens = heuristicEngine.tokenize(text, in: r, proseMode: false)
                    .filter { t in
                        switch t.scope {
                        case .keyword, .constantLanguage, .variableLanguage: return true
                        default: return false
                        }
                    }
                tokens = tsTokens + hTokens
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    func applyHighlighting(to storage: NSTextStorage, range: NSRange, font: NSFont? = nil) {
        let text = storage.string
        var tokens = tokenize(text, range: range)
        let theme = ThemeRegistry.shared.current
        let baseFont = font ?? self.baseFont
        // Line spacing must live in the text's own paragraph style: NSTextView
        // ignores `defaultParagraphStyle.lineSpacing` for text that carries no
        // explicit .paragraphStyle attribute (it is typing-only). The gutter
        // measures line height from this same spacing, so omitting it here makes
        // every line render ~Npt shorter than the number column and the two drift
        // progressively apart down the file.
        let baseParagraphStyle = NSMutableParagraphStyle()
        baseParagraphStyle.lineSpacing = ThemeSettings.shared.resolvedLineSpacing(for: theme)

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.editorForeground,
            .font: baseFont,
            .paragraphStyle: baseParagraphStyle,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
            .obliqueness: 0,
        ]

        storage.setAttributes(baseAttrs, range: range)

        // ─── Fenced code blocks: deterministic bounds from actual ```/~~~ delimiters ───
        // Tree-sitter's markdown parser produces unpredictable error-recovery nodes
        // for fenced_code_block, indented_code_block, html_block — all map to .codeBlock.
        // We discard ALL engine-produced .codeBlock tokens and build our own from the
        // document's actual fence delimiters. The pair-based tokens include both opening
        // and closing fence lines so the entire block is visually styled as code.
        let fenceStarts = Self.pairedFenceRanges(in: text)
        let ns = text as NSString

        // 1. Strip ALL .codeBlock tokens from the engine (fenced, indented, html — all).
        tokens.removeAll { $0.scope == .codeBlock }

        // 2. Add pair-based code-block tokens for each sequential fence pair.
        //    Range: [opening-fence-line-start, closing-fence-line-end)
        //    Also add .punctuation tokens for the ``` / ~~~ delimiter lines so
        //    they receive distinct styling (TextMate: punctuation.definition.raw).
        for i in stride(from: 0, to: fenceStarts.count - 1, by: 2) {
            let openLoc = fenceStarts[i]
            let closeLineLoc = fenceStarts[i + 1]
            let closeEnd = ns.lineRange(for: NSRange(location: closeLineLoc, length: 0)).upperBound
            let len = closeEnd - openLoc
            if len > 0 {
                tokens.append(Token(range: NSRange(location: openLoc, length: len),
                                    scope: .codeBlock))
            }
            // Opening fence line: from ``` to end of line
            let openLineEnd = ns.lineRange(for: NSRange(location: openLoc, length: 0)).upperBound
            tokens.append(Token(range: NSRange(location: openLoc, length: openLineEnd - openLoc),
                                scope: .punctuation))
            // Closing fence line: from ``` to end of line
            let closeLineEnd = ns.lineRange(for: NSRange(location: closeLineLoc, length: 0)).upperBound
            tokens.append(Token(range: NSRange(location: closeLineLoc, length: closeLineEnd - closeLineLoc),
                                scope: .punctuation))
        }

        // 3. Clip all tokens to the target range — fence pairs span the entire document
        //    but incremental edits only highlight a partial range. Out-of-range tokens
        //    cause NSRangeException in storage.addAttributes.
        tokens = tokens.compactMap { token in
            let clipped = NSIntersectionRange(token.range, range)
            guard clipped.length > 0 else { return nil }
            return Token(range: clipped, scope: token.scope)
        }

        // 4. Remove inline code tokens that overlap code block boundaries.
        //    The heuristic regex `[^`]+` can match the last backtick of a ``` fence
        //    as the opening delimiter, bleeding monospace styling into the gap between blocks.
        let cbRanges = tokens.filter { $0.scope == .codeBlock }.map { $0.range }
        tokens.removeAll { token in
            guard token.scope == .inlineCode else { return false }
            let te = token.range.location + token.range.length
            return cbRanges.contains { cb in
                token.range.location < cb.location + cb.length && te > cb.location
            }
        }

        // 4. Remove bleed inlineCode tokens — the heuristic regex can match
        //    a closing backtick as opener and span to the next opening backtick,
        //    creating a spurious token that overlaps legitimate ones.
        //    Sort by location; keep earlier tokens, discard later overlapping ones.
        let icTokens = tokens.enumerated().filter { $0.element.scope == .inlineCode }
            .sorted { $0.element.range.location < $1.element.range.location }
        var bleedIndices = Set<Int>()
        var lastKept: (idx: Int, end: Int)? = nil
        for (idx, t) in icTokens {
            if let prev = lastKept, t.range.location < prev.end {
                bleedIndices.insert(idx)  // overlaps previous → bleed
            } else {
                lastKept = (idx, t.range.location + t.range.length)
            }
        }
        if !bleedIndices.isEmpty {
            tokens = tokens.enumerated().filter { !bleedIndices.contains($0.offset) }.map { $0.element }
        }

        // 4b. Deduplicate same-range tokens — tree-sitter may produce multiple captures
        //     for the same node (e.g. a specific nested pattern + the catch-all identifier).
        //     The query returns captures in declaration order, so the first capture is the
        //     most specific. Keep the first, discard later duplicates for the same range.
        //
        //     However, heuristic string-detail tokens (.metaEmbedded, .constantCharacterEscape)
        //     are appended *after* tree-sitter tokens. For string content, the heuristic
        //     scopes are more meaningful than generic punctuation. Sort with priority so
        //     string-detail scopes win over generic scopes at the same position.
        let detailPriority: Set<TokenScope> = [.metaEmbedded, .constantCharacterEscape]
        tokens.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length < b.range.length }
            let aDetail = detailPriority.contains(a.scope)
            let bDetail = detailPriority.contains(b.scope)
            if aDetail != bDetail { return aDetail }
            return false
        }
        // Keep the first token per exact (location, length) pair — tree-sitter
        // may emit duplicate captures for one node. Unlike the old lastEnd walk,
        // this no longer drops *nested* tokens (embedded syntax inside a code
        // block, escapes inside a string) whose ranges overlap but are not equal.
        var seen = Set<String>()
        var deduped: [Token] = []
        for t in tokens {
            let key = "\(t.range.location):\(t.range.length)"
            if !seen.contains(key) {
                seen.insert(key)
                deduped.append(t)
            }
        }
        tokens = deduped

        // 5. Scope priority: suppressive scopes (comment, string) must block
        //    other tokens within their ranges so keywords/numbers don't bleed
        //    through inside comments or string literals.
        //    Exception: string-detail tokens (interpolation punctuation,
        //    metaEmbedded content, escape sequences) are *legitimate* interior
        //    scopes and must NOT be suppressed.
        let suppressiveScopes: Set<TokenScope> = [.comment, .string]
        let stringDetail: Set<TokenScope> = [.punctuation, .metaEmbedded, .constantCharacterEscape]
        let suppressiveRanges = tokens.filter { suppressiveScopes.contains($0.scope) }.map { $0.range }
        if !suppressiveRanges.isEmpty {
            tokens.removeAll { token in
                if suppressiveScopes.contains(token.scope) { return false }
                if token.scope == .codeBlock { return false }
                if stringDetail.contains(token.scope) { return false }
                let te = token.range.location + token.range.length
                return suppressiveRanges.contains { sr in
                    token.range.location >= sr.location && te <= sr.location + sr.length
                }
            }
        }

        // 6. Sort: codeBlock first (base layer — background + monospace font),
        //    then embedded syntax tokens override colors on top.
        tokens.sort { a, b in
            if a.scope == .codeBlock && b.scope != .codeBlock { return true }
            if b.scope == .codeBlock && a.scope != .codeBlock { return false }
            return a.range.location < b.range.location
        }

        for token in tokens {
            let style = theme.style(for: token.scope)
            let attrs = self.attributes(for: token, style: style, range: token.range,
                                        storage: storage, baseFont: baseFont)
            storage.addAttributes(attrs, range: token.range)
        }
    }

    /// Scan document for ```/~~~ fence lines. Returns sorted array of fence start positions.
    /// Paired: even indices are opening fences, odd indices are closing fences.
    private static func pairedFenceRanges(in text: String) -> [Int] {
        guard let re = try? NSRegularExpression(
            pattern: "(?m)^(```|~~~)[^\\n]*$", options: []
        ) else { return [] }

        let full = NSRange(location: 0, length: (text as NSString).length)
        var positions: [Int] = []
        re.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
            guard let m = m else { return }
            positions.append(m.range.location)
        }
        return positions
    }

    /// Build attribute dictionary for a single token.
    private func attributes(for token: Token, style: TokenStyle, range: NSRange,
                            storage: NSTextStorage, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        let fg = style.foreground ?? ThemeRegistry.shared.current.editorForeground
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: fg]

        // Apply backgrounds. If the color already has embedded alpha (< 1.0),
        // use it as-is (the converter preserved the original alpha). Otherwise
        // apply forced translucency for readability: 0.25 for codeBlock, 0.35
        // for other scopes (string backgrounds, constant backgrounds, etc.).
        // When the theme defines no background at all, derive a subtle tint
        // from the foreground colour so strings are always visually distinct.
        if let bg = style.background {
            if bg.alphaComponent < 0.99 {
                attrs[.backgroundColor] = bg
            } else {
                let alpha: CGFloat = token.scope == .codeBlock ? 0.25 : 0.35
                attrs[.backgroundColor] = bg.withAlphaComponent(alpha)
            }
        } else {
            let stringLike: Set<TokenScope> = [.string, .metaEmbedded, .constantCharacterEscape, .stringEscape]
            if stringLike.contains(token.scope) {
                attrs[.backgroundColor] = fg.withAlphaComponent(0.12)
            }
        }

        if style.isUnderline == true {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.isStrikethrough == true {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        // Font computation (unchanged logic, extracted for clarity)
        let scopeNeedsMono = token.scope == .codeBlock || token.scope == .inlineCode
        let existingFont: NSFont = scopeNeedsMono
            ? ThemeSettings.shared.resolvedMonoFont.withSize(baseFont.pointSize)
            : (storage.attribute(.font, at: range.location,
                                  effectiveRange: nil) as? NSFont ?? baseFont)
        let targetSize: CGFloat = style.fontSize.map {
            $0 < 10 ? baseFont.pointSize * $0 : $0
        } ?? existingFont.pointSize

        var font = existingFont
        if targetSize != existingFont.pointSize || style.fontName != nil {
            let desc: NSFontDescriptor
            if let family = style.fontName {
                desc = NSFontDescriptor().withFamily(family)
            } else {
                desc = existingFont.fontDescriptor.withSize(targetSize)
            }
            font = NSFont(descriptor: desc, size: targetSize) ?? existingFont
        }

        // Merge traits: read existing font traits + requested bold/italic,
        // then use withSymbolicTraits to get a font that has ALL desired traits.
        // This preserves bold when adding italic (and vice versa), unlike
        // convert(_:toHaveTrait:) which can lose existing traits.
        var traits = font.fontDescriptor.symbolicTraits
        if style.isBold == true { traits.insert(.bold) }
        if style.isItalic == true { traits.insert(.italic) }

        if traits != font.fontDescriptor.symbolicTraits {
            let desc = font.fontDescriptor.withSymbolicTraits(traits)
            let merged = NSFont(descriptor: desc, size: font.pointSize) ?? font
            if style.isItalic == true && !merged.fontDescriptor.symbolicTraits.contains(.italic) {
                // Font doesn't have an italic variant → faux italic via skew
                attrs[.obliqueness] = 0.2
            }
            font = merged
        }

        if scopeNeedsMono || font != existingFont { attrs[.font] = font }

        return attrs
    }

}