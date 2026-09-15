import AppKit
import XCTest
@testable import AetherCodex

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    func testStatusHTMLAndInlineCode() {
        XCTAssertEqual(String(renderInline("<p>Consulting the hermetic oracle</p>").characters), "Consulting the hermetic oracle")
        XCTAssertEqual(String(renderInline("Array<T> &amp; value").characters), "Array<T> & value")
    }

    func testTablesTasksQuotesAndCode() {
        let blocks = MarkdownBlock.parse("| Name | Value |\n| --- | --- |\n| A | B |\n\n> Thought\n\n---\n\n- [x] done\n\n```swift\nlet n = 1\n```")
        XCTAssertEqual(blocks.count, 5)
        guard case .table(let header, let rows) = blocks[0].kind else { return XCTFail("Missing native table") }
        XCTAssertEqual(header, ["Name", "Value"])
        XCTAssertEqual(rows, [["A", "B"]])
        guard case .code(let code, let language) = blocks.last!.kind else { return XCTFail("Missing code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let n = 1")
        XCTAssertEqual(MarkdownBlock.cells("| a\\|b | `c|d` |"), ["a|b", "`c|d`"])
    }

    func testEditableMarkdownTableRoundTrip() throws {
        _ = NSApplication.shared
        let document = RichTextDocument()
        try document.load(Data("| Name | Value |\n| --- | --- |\n| A | B |\n".utf8), markdown: true)
        let range = (document.textView.string as NSString).range(of: "A")
        document.textView.insertText("Changed", replacementRange: range)
        let saved = String(decoding: try document.encoded(), as: UTF8.self)
        XCTAssertTrue(saved.contains("| Changed | B |"), saved)
        let style = document.textView.attributedString().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.textBlocks.first is NSTextTableBlock)
    }

    func testNativeTableSurvivesRTF() throws {
        let table = RichTextTable.make([["A", "B"], ["C", "D"]])
        let data = try table.data(from: NSRange(location: 0, length: table.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let read = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let style = read.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.textBlocks.first is NSTextTableBlock)
    }

    // MARK: - Round-trip (byte-exact)

    /// The core guarantee: `render` → `source()` reconstructs the *exact* Markdown
    /// bytes for untouched structural content. Headings and fenced code blocks are
    /// hidden from the visible text (native `headerLevel` / `NSTextBlock`), yet the
    /// original source survives because each block carries its pristine bytes as
    /// metadata (`originalLine` / `originalBlock`) that `source()` replays verbatim.
    func testHeadingAndCodeBlockRoundTripByteExact() {
        _ = NSApplication.shared
        let source = "# Title\n\nIntro paragraph.\n\n## Section\n\n```swift\nlet n = 1\nprint(n)\n```\n"
        let rendered = MarkdownRichCodec.render(source)
        XCTAssertEqual(MarkdownRichCodec.source(rendered), source)
    }

    /// The full editing vocabulary round-trips byte-exact when unmodified: inline
    /// emphasis, lists (bullet/ordered/task), block quotes, native tables, fenced
    /// code, and horizontal rules all survive `render` → `source()` untouched.
    func testFullVocabularyRoundTripByteExact() {
        _ = NSApplication.shared
        let source = "# Heading One\n\n**Bold** and *italic* and `inline code` and ~~strike~~ and [link](https://example.com).\n\n## Heading Two\n\n- bullet one\n- bullet two\n\n1. first\n2. second\n\n- [x] done\n- [ ] todo\n\n> quoted **thought**\n\n| Name | Value |\n| --- | --- |\n| A | B |\n\n```swift\nlet n = 1\n```\n\n---\n\nThe end.\n"
        let rendered = MarkdownRichCodec.render(source)
        XCTAssertEqual(MarkdownRichCodec.source(rendered), source)
    }

    /// The box model: structural blocks (quote + fenced code) carry a native
    /// `NSTextBlock` whose width is an explicit 100% of the text column — the
    /// simplified HTML box model (`RichTextBlockStyle`) rather than content-hugging.
    func testBlockElementsSpanFullColumnViaBoxModel() {
        _ = NSApplication.shared
        let source = "> quote\n\n```swift\nlet n = 1\n```\n"
        let rendered = MarkdownRichCodec.render(source)
        var blocksFound = 0
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextBlock else { return }
            XCTAssertEqual(block.value(for: .width), 100)
            XCTAssertEqual(block.valueType(for: .width), .percentageValueType)
            blocksFound += 1
        }
        XCTAssertGreaterThanOrEqual(blocksFound, 2)
    }
}