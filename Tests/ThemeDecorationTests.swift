import AppKit
import XCTest
@testable import AetherCodex

@MainActor
final class ThemeDecorationTests: XCTestCase {
    func testBackdropSamplesDesktopAndUpdatesMaterial() {
        let view = NSVisualEffectView()
        WindowBackdrop(strength: 0.25).configure(view)
        XCTAssertEqual(view.blendingMode, .behindWindow)
        XCTAssertEqual(view.state, .active)
        XCTAssertEqual(view.material, .popover)
        WindowBackdrop(strength: 0.65).configure(view)
        XCTAssertEqual(view.material, .sidebar)
        XCTAssertEqual(view.blendingMode, .behindWindow)
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
        let gutter = EditorContainerView.makeGutter(document: model, theme: theme,
                                                  baseFont: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular))
        XCTAssertEqual(gutter.font.pointSize, 13.6, accuracy: 0.01)
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
