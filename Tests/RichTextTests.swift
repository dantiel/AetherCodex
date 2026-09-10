import AppKit
import SwiftUI
import XCTest
@testable import AetherCodex

@MainActor
final class RichTextTests: XCTestCase {
    func testEditorSwitchesMarkdownModesAndSavesRichEdits() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Title\n\nHello\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let editor = EditorViewController()
        _ = editor.view
        editor.openFile(url)
        XCTAssertTrue(editor.richDocument.active)
        editor.showMarkdownSource()
        XCTAssertFalse(editor.richDocument.active)
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.textView.string, "# Title\n\nHello\n")
        editor.showRichText()
        let range = (editor.richDocument.textView.string as NSString).range(of: "Hello")
        editor.richDocument.textView.insertText("Welcome", replacementRange: range)
        XCTAssertTrue(editor.isDirty)
        editor.saveDocument()
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Title\n\nWelcome\n")
    }

    func testTextSurfaceWrapsAndScrollsWithoutGutter() throws {
        _ = NSApplication.shared
        let document = RichTextDocument()
        try document.load(Data(("# A quiet workspace\n\n" + String(repeating: "A flowing paragraph with **emphasis** and enough words to wrap onto several lines.\n\n", count: 60)).utf8), markdown: true)
        let host = NSHostingView(rootView: RichTextSurface(document: document, theme: ThemeRegistry.shared.current, showSource: {}))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 500)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(document.textView.enclosingScrollView)
        document.textView.layoutManager?.ensureLayout(for: document.textView.textContainer!)
        document.textView.sizeToFit()
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertFalse(scroll.hasVerticalRuler)
        // The SwiftUI scroll host now supplies the wrapping width explicitly.
        XCTAssertFalse(document.textView.textContainer!.widthTracksTextView)
        XCTAssertEqual(document.textView.textContainer!.containerSize.width,
                       620 - 28 - document.textView.textContainerInset.width * 2, accuracy: 1)
        XCTAssertGreaterThan(document.textView.frame.height, scroll.contentSize.height + 500)
        XCTAssertLessThanOrEqual(document.textView.frame.width, scroll.contentSize.width + 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 299)
    }

    func testUntouchedMarkdownIsByteExact() throws {
        _ = NSApplication.shared
        let document = RichTextDocument()
        let source = Data("# Title\r\n\r\n**bold** and *soft*\r\n![image](asset.png)\r\n".utf8)
        try document.load(source, markdown: true)
        XCTAssertTrue(document.active)
        XCTAssertEqual(try document.encoded(), source)
        XCTAssertFalse(document.textView.string.hasPrefix("# "))
    }

    func testMarkdownRetainsUntouchedSyntaxAfterEditingAnotherParagraph() {
        let source = "# Title\n\n**bold** and *soft*\n![image](asset.png)\n| a | b |\n\\*literal\\*\n"
        let rich = NSMutableAttributedString(attributedString: MarkdownRichCodec.render(source))
        rich.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Changed")
        XCTAssertEqual(MarkdownRichCodec.source(rich), source.replacingOccurrences(of: "Title", with: "Changed"))
    }

    func testRichTextSavePreservesFormattingAndEdits() throws {
        _ = NSApplication.shared
        let original = NSAttributedString(string: "Hello", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.red])
        let data = try original.data(from: NSRange(location: 0, length: original.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let document = RichTextDocument()
        try document.load(data, markdown: false)
        var changes = 0
        document.onChange = { changes += 1 }
        document.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        let saved = try NSAttributedString(data: document.encoded(), options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        XCTAssertEqual(saved.string, "Hello!")
        XCTAssertGreaterThan(changes, 0)
        let font = try XCTUnwrap(saved.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testMarkdownFormattingIsSaved() throws {
        _ = NSApplication.shared
        let document = RichTextDocument()
        try document.load(Data("hello world\n".utf8), markdown: true)
        document.textView.setSelectedRange(NSRange(location: 0, length: 5))
        document.trait(.boldFontMask)
        XCTAssertEqual(String(decoding: try document.encoded(), as: UTF8.self), "**hello** world\n")
    }
}
