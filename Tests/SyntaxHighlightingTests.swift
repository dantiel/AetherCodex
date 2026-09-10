import XCTest
import Cocoa
@testable import AetherCodex

final class SyntaxHighlightingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Initialize NSApplication for tests — ThemeSettings needs NSApp
        if NSApp == nil {
            _ = NSApplication.shared
        }
    }

    // ── Helpers ──

    /// Resolve a theme by name substring
    func findTheme(containing name: String) -> SyntaxTheme? {
        ThemeRegistry.shared.themes.first { $0.name.lowercased().contains(name.lowercased()) }
    }

    /// Create engine + set Swift language
    func makeSwiftEngine() -> TreeSitterEngine {
        let engine = TreeSitterEngine()
        let ok = engine.setLanguage(forExtension: "swift")
        XCTAssertTrue(ok, "TreeSitterEngine should load Swift language")
        return engine
    }

    /// Tokenize source text with Swift engine, full range
    func tokenize(_ source: String, engine: TreeSitterEngine) -> [Token] {
        engine.tokenize(source, in: NSRange(location: 0, length: source.utf16.count))
    }

    // MARK: - Theme cascade tests

    func testAmigaThemeHasMetaEmbeddedScope() throws {
        guard let amiga = findTheme(containing: "amiga") else {
            throw XCTSkip("Amiga WB theme not found")
        }
        ThemeRegistry.shared.activate(named: amiga.name)
        let theme = ThemeRegistry.shared.current

        let style = theme.style(for: .metaEmbedded)
        // meta.embedded should have bg (#8A9ECB) — blue-gray
        XCTAssertNotNil(style.background, "metaEmbedded requires background for visual distinctness")
    }

    func testAmigaThemeHasConstantCharacterEscape() throws {
        guard let amiga = findTheme(containing: "amiga") else {
            throw XCTSkip("Amiga WB theme not found")
        }
        ThemeRegistry.shared.activate(named: amiga.name)
        let theme = ThemeRegistry.shared.current

        let style = theme.style(for: .constantCharacterEscape)
        // constant.character should have peach fg (#FFA995) + blue bg (#0000FF33)
        XCTAssertNotNil(style.foreground, "constantCharacterEscape requires foreground")
        XCTAssertNotNil(style.background, "constantCharacterEscape requires background")
    }

    // MARK: - String interpolation token tests

    func testInterpolationProducesMetaEmbeddedTokens() throws {
        let engine = makeSwiftEngine()
        let source = #"let msg = "Hello \(name)!""#

        let tokens = tokenize(source, engine: engine)
        let scopes = tokens.map(\.scope)

        print("\n=== Tokens for: \(source) ===")
        dumpTokens(source, tokens)

        XCTAssertTrue(scopes.contains(.metaEmbedded),
                      "Expected .metaEmbedded in token scopes: \(scopes)")
        XCTAssertTrue(scopes.contains(.string),
                      "Expected .string for outer quotes and plain text: \(scopes)")
    }

    func testEscapeProducesConstantCharacterEscapeTokens() throws {
        let engine = makeSwiftEngine()
        let source = #"let msg = "Line 1\nLine 2""#

        let tokens = tokenize(source, engine: engine)
        let scopes = tokens.map(\.scope)

        print("\n=== Tokens for: \(source) ===")
        dumpTokens(source, tokens)

        XCTAssertTrue(scopes.contains(.constantCharacterEscape),
                      "Expected .constantCharacterEscape in token scopes: \(scopes)")
    }

    func testInterpolationTokenPositions() throws {
        let engine = makeSwiftEngine()
        let source = #"let msg = "Hello \(name)!""#

        let tokens = tokenize(source, engine: engine)

        let ns = source as NSString
        print("\n=== Token positions ===")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = ns.substring(with: t.range)
            print("  [\(t.range.location),\(t.range.upperBound)] \"\(text)\" -> \(t.scope)")
        }

        // Find \( token (now .metaEmbedded scope)
        let interpPunct = tokens.filter {
            $0.scope == .metaEmbedded &&
            ns.substring(with: $0.range) == "\\("
        }
        XCTAssertFalse(interpPunct.isEmpty, "Missing \\( metaEmbedded token")

        // Find "name" metaEmbedded token
        let meta = tokens.filter {
            $0.scope == .metaEmbedded &&
            ns.substring(with: $0.range) == "name"
        }
        XCTAssertFalse(meta.isEmpty, "Missing metaEmbedded 'name' token")

        // Find ) token (now .metaEmbedded scope)
        let closePunct = tokens.filter {
            $0.scope == .metaEmbedded &&
            ns.substring(with: $0.range) == ")"
        }
        XCTAssertFalse(closePunct.isEmpty, "Missing ) metaEmbedded token")
    }

    func testNestedParenInterpolation() throws {
        let engine = makeSwiftEngine()
        let source = #"let result = "\(a + (b * c))""#

        let tokens = tokenize(source, engine: engine)
        let ns = source as NSString
        // Filter metaEmbedded tokens, skip the \( and ) punctuation
        let metaTokens = tokens.filter {
            $0.scope == .metaEmbedded &&
            !["\\(", ")"].contains(ns.substring(with: $0.range))
        }

        XCTAssertFalse(metaTokens.isEmpty, "Should handle nested parens")
        if let meta = metaTokens.first {
            let content = ns.substring(with: meta.range)
            XCTAssertEqual(content, "a + (b * c)", "Nested expression should be fully captured")
        }
    }

    func testMultipleEscapesAndInterpolations() throws {
        let engine = makeSwiftEngine()
        let source = #"""
        let a = "Hello \(name)!"
        let b = "Tab\there"
        let c = "Unicode \u{1F600}"
        let d = "Quote \"here\""
        let e = "Multi\nLine"
        """#

        let tokens = tokenize(source, engine: engine)
        let metaCount = tokens.filter { $0.scope == .metaEmbedded }.count
        let escapeCount = tokens.filter { $0.scope == .constantCharacterEscape }.count
        let punctCount = tokens.filter { $0.scope == .punctuation }.count

        print("\n=== Multiple test ===")
        print("metaEmbedded: \(metaCount)")
        print("constantCharacterEscape: \(escapeCount)")
        print("punctuation: \(punctCount)")
        print("total tokens: \(tokens.count)")

        XCTAssertGreaterThan(metaCount, 0, "Should have interpolation")
        XCTAssertGreaterThanOrEqual(escapeCount, 3, "Should have \\t, \\u{...}, \\\", \\n")
    }

    // MARK: - Full pipeline: tokenize → resolve colors

    func testFullPipelineMetaEmbeddedHasBackground() throws {
        guard let amiga = findTheme(containing: "amiga") else {
            throw XCTSkip("Amiga WB theme not found")
        }
        ThemeRegistry.shared.activate(named: amiga.name)

        let engine = makeSwiftEngine()
        let source = #"let msg = "Hello \(name)!""#
        let tokens = tokenize(source, engine: engine)
        let theme = ThemeRegistry.shared.current

        for token in tokens where token.scope == .metaEmbedded {
            let style = theme.style(for: token.scope)
            print("metaEmbedded: fg=\(style.foreground?.description ?? "nil") bg=\(style.background?.description ?? "nil")")
            XCTAssertNotNil(style.background,
                "metaEmbedded must resolve background. Got fg=\(style.foreground?.description ?? "nil") bg=nil")
        }
    }

    func testFullPipelineEscapeHasForegroundAndBackground() throws {
        guard let amiga = findTheme(containing: "amiga") else {
            throw XCTSkip("Amiga WB theme not found")
        }
        ThemeRegistry.shared.activate(named: amiga.name)

        let engine = makeSwiftEngine()
        let source = #"let msg = "Tab\there""#
        let tokens = tokenize(source, engine: engine)
        let theme = ThemeRegistry.shared.current

        for token in tokens where token.scope == .constantCharacterEscape {
            let style = theme.style(for: token.scope)
            print("constantCharacterEscape: fg=\(style.foreground?.description ?? "nil") bg=\(style.background?.description ?? "nil")")
            XCTAssertNotNil(style.foreground,
                "constantCharacterEscape must resolve foreground")
            XCTAssertNotNil(style.background,
                "constantCharacterEscape must resolve background")
        }
    }

    func testFullPipelineDump() throws {
        guard let amiga = findTheme(containing: "amiga") else {
            throw XCTSkip("Amiga WB theme not found")
        }
        ThemeRegistry.shared.activate(named: amiga.name)

        let engine = makeSwiftEngine()
        let source = #"let msg = "Hello \(name)!\n""#
        let tokens = tokenize(source, engine: engine)
        let theme = ThemeRegistry.shared.current
        let ns = source as NSString

        print("\n╔══════════════════════════════════════════════╗")
        print("║  FULL PIPELINE DUMP                          ║")
        print("╠══════════════════════════════════════════════╣")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = ns.substring(with: t.range)
            let style = theme.style(for: t.scope)
            let ts = TokenScope(rawValue: t.scope.rawValue)
            print("  [\(String(format: "%3d", t.range.location))-\(String(format: "%3d", t.range.upperBound))] \"\(text.padding(toLength: 12, withPad: " ", startingAt: 0))\" → \(t.scope.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0))  fg=\(style.foreground?.hexString ?? "nil".padding(toLength: 9, withPad: " ", startingAt: 0))  bg=\(style.background?.hexString ?? "nil")")
        }
        print("╚══════════════════════════════════════════════╝")
    }

    // MARK: - Suppression logic test

    func testSuppressionPreservesMetaEmbedded() throws {
        let engine = makeSwiftEngine()
        let source = #"let msg = "Hello \(name)!""#
        var tokens = engine.tokenize(source, in: NSRange(location: 0, length: source.utf16.count))

        let suppressiveScopes: Set<TokenScope> = [.comment, .string]
        let stringDetail: Set<TokenScope> = [.metaEmbedded, .constantCharacterEscape]
        let suppressiveRanges = tokens.filter { suppressiveScopes.contains($0.scope) }.map { $0.range }

        print("=== Suppression test ===")
        print("suppressiveRanges: \(suppressiveRanges)")

        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = (source as NSString).substring(with: t.range)
            let inside = suppressiveRanges.contains { sr in
                t.range.location >= sr.location &&
                t.range.location + t.range.length <= sr.location + sr.length
            }
            print("  [\(t.range.location),\(t.range.upperBound)] \"\(text)\" -> \(t.scope)  insideString=\(inside)")
        }

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

        print("=== After suppression ===")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = (source as NSString).substring(with: t.range)
            print("  [\(t.range.location),\(t.range.upperBound)] \"\(text)\" -> \(t.scope)")
        }

        let metaTokens = tokens.filter { $0.scope == .metaEmbedded }
        XCTAssertFalse(metaTokens.isEmpty,
            "metaEmbedded MUST survive suppression. Tokens after: \(tokens.map { ($0.scope, (source as NSString).substring(with: $0.range)) })")
    }
}

// MARK: - Diagnostic helpers

extension SyntaxHighlightingTests {
    func dumpTokens(_ source: String, _ tokens: [Token]) {
        let ns = source as NSString
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = ns.substring(with: t.range)
            print("  [\(t.range.location),\(t.range.upperBound)] \"\(text)\" -> \(t.scope)")
        }
        print("  Total: \(tokens.count) tokens")
    }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "???" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        let a = Int((rgb.alphaComponent * 255).rounded())
        if a == 255 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

// MARK: - Type / class / keyword token tests

extension SyntaxHighlightingTests {

    func testTypeTokenIsProduced() throws {
        let engine = makeSwiftEngine()
        let source = "class MyClass {}"
        let tokens = engine.tokenize(source, in: NSRange(location: 0, length: source.utf16.count))

        let typeTokens = tokens.filter { $0.scope == .entityNameType || $0.scope == .type }
        XCTAssertTrue(typeTokens.contains { (source as NSString).substring(with: $0.range) == "MyClass" },
                      "Expected a type-name token on the declared class name")

        print("=== Type tokens for '\(source)' ===")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = (source as NSString).substring(with: t.range)
            print("  [\(t.range)] \"\(text)\" → \(t.scope.rawValue)")
        }
    }

    func testTypeAnnotationProducesTypeToken() throws {
        let engine = makeSwiftEngine()
        let source = "var name: String"
        let tokens = engine.tokenize(source, in: NSRange(location: 0, length: source.utf16.count))

        let typeTokens = tokens.filter { $0.scope == .type || $0.scope == .typeSupport }
        XCTAssertFalse(typeTokens.isEmpty, "Expected .type or .typeSupport on type annotation 'String'")

        print("=== Type annotation tokens ===")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = (source as NSString).substring(with: t.range)
            print("  [\(t.range)] \"\(text)\" → \(t.scope.rawValue)")
        }
    }

    func testConstructorIsProduced() throws {
        let engine = makeSwiftEngine()
        let source = "init() {}"
        let tokens = engine.tokenize(source, in: NSRange(location: 0, length: source.utf16.count))

        print("=== Constructor tokens ===")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = (source as NSString).substring(with: t.range)
            print("  [\(t.range)] \"\(text)\" → \(t.scope.rawValue)")
        }
        // init should produce a token — either .type (constructor) or something
        let hasInit = tokens.contains { token in
            (source as NSString).substring(with: token.range) == "init" &&
                (token.scope == .entityNameFunction || token.scope == .type)
        }
        XCTAssertTrue(hasInit, "Expected init to produce a styled token")
    }

    func testBooleanProducesConstantToken() throws {
        let engine = makeSwiftEngine()
        let source = "let flag = true"
        let tokens = engine.tokenize(source, in: NSRange(location: 0, length: source.utf16.count))

        print("=== Boolean tokens ===")
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            let text = (source as NSString).substring(with: t.range)
            print("  [\(t.range)] \"\(text)\" → \(t.scope.rawValue)")
        }
        let constantTokens = tokens.filter { $0.scope.rawValue.hasPrefix("constant") }
        XCTAssertFalse(constantTokens.isEmpty, "Expected constant token for 'true'")
    }

    func testThemeHasTypeScopeResolved() throws {
        let theme = ThemeRegistry.shared.current
        let typeStyle = theme.style(for: .type)
        print("=== Type scope cascade ===")
        print("  fg: \(typeStyle.foreground?.hexString ?? "nil")")
        print("  bg: \(typeStyle.background?.hexString ?? "nil")")
        // Type scope should resolve to something — if nil, it falls to editorForeground
        XCTAssertNotNil(typeStyle.foreground, "Type scope should have a resolved foreground")
    }

    func testPlainStringProducesStringTokens() throws {
        let engine = makeSwiftEngine()
        let source = #"let msg = "Hello World""#

        let tokens = tokenize(source, engine: engine)

        print("\n=== Plain string tokens ===")
        dumpTokens(source, tokens)

        let stringTokens = tokens.filter { $0.scope == .string }
        XCTAssertFalse(stringTokens.isEmpty,
                       "Expected .string tokens for plain (non-interpolated) string literal")

        // Verify the string content is covered
        let ns = source as NSString
        for t in stringTokens {
            let text = ns.substring(with: t.range)
            print("  .string: \"\(text)\"")
        }
    }
}
