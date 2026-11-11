import AppKit
import XCTest
@testable import AetherCodex

@MainActor
final class ThemeDecorationTests: XCTestCase {
    /// The glass is SwiftUI-only: strength maps to a material *name* at the same
    /// thresholds the SwiftUI `Material` mapping uses. No `NSVisualEffectView`
    /// is involved anywhere in the chrome.
    func testGlassMaterialNamesFollowStrengthThresholds() {
        XCTAssertEqual(glassMaterialName(for: 0.0), "Ultra Thin")
        XCTAssertEqual(glassMaterialName(for: 0.19), "Ultra Thin")
        XCTAssertEqual(glassMaterialName(for: 0.25), "Thin")
        XCTAssertEqual(glassMaterialName(for: 0.5), "Regular")
        XCTAssertEqual(glassMaterialName(for: 0.65), "Thick")
        XCTAssertEqual(glassMaterialName(for: 0.95), "Ultra Thick")
    }

    func testSyntaxRuleMapsAreLoadedFromYAML() throws {
        let yaml = "rules:\n  - scope: keyword\n    pattern: 'if|else'\n  - scope: string\n    pattern: 'quoted'\n"
        let rules = try XCTUnwrap(SimpleYaml.load(yaml)["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0]["pattern"] as? String, "if|else")
        XCTAssertEqual(rules[1]["scope"] as? String, "string")
    }
    func testGutterUsesBaseFontRatherThanHeadingFont() throws {
        let theme = try XCTUnwrap(ThemeLoader.theme(from: [
            "name": "test", "kind": "light", "scopes": ["plain": "0X111111"],
            "rulerForeground": "0X222222", "sidebarAccent": "0X335577"
        ]))
        let model = EditorDocumentModel()
        model.attributedString = NSAttributedString(string: "Heading\ntext", attributes: [.font: NSFont.systemFont(ofSize: 48)])
        let baseFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let gutter = EditorContainerView.makeGutter(document: model, theme: theme, baseFont: baseFont)
        // Shape, not value: the gutter face derives from the *base* font — never
        // from the document's first-line attributes (a 48pt heading) — and stays
        // slightly smaller than the code face it numbers.
        XCTAssertEqual(gutter.font.pointSize, baseFont.pointSize * EditorGutterStyle.rulerFontScale,
                       accuracy: 0.01)
        XCTAssertLessThan(gutter.font.pointSize, baseFont.pointSize)
        XCTAssertGreaterThan(gutter.font.pointSize, baseFont.pointSize * 0.7)
        XCTAssertEqual(theme.sidebarAccent.usingColorSpace(.deviceRGB)!.blueComponent, 0x77 / 255.0, accuracy: 0.001)
    }

    func testTemplateTokensRecognizeTagsClassesAndCoffeeKeywords() {
        let haml = "%section.card\n  = @title\n  -# comment"
        let tokens = TemplateSyntaxEngine.tokenize(haml, extension: "coffeehaml", range: NSRange(location: 0, length: (haml as NSString).length))
        XCTAssertTrue(tokens.contains { $0.scope == .tag })
        XCTAssertTrue(tokens.contains { $0.scope == .attribute })
        XCTAssertTrue(tokens.contains { $0.scope == .comment })
        let coffee = "square = (x) -> x * x if yes"
        let coffeeTokens = TemplateSyntaxEngine.tokenize(coffee, extension: "coffee", range: NSRange(location: 0, length: (coffee as NSString).length))
        XCTAssertTrue(coffeeTokens.contains { $0.scope == .keyword })
        XCTAssertTrue(coffeeTokens.contains { $0.scope == .constantLanguage })
    }

    func testRegeneratedThemesLoad() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AetherOracle/resources/Themes")
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" }
        XCTAssertGreaterThan(urls.count, 100)
        for url in urls {
            XCTAssertNotNil(ThemeLoader.loadTheme(from: url.path), url.lastPathComponent)
        }
    }
}