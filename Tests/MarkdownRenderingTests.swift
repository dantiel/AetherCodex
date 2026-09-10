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
}
