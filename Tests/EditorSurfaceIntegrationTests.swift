import AppKit
import SwiftUI
import XCTest
@testable import AetherCodex

@MainActor
final class EditorSurfaceIntegrationTests: XCTestCase {
    func testLongDocumentHasScrollableExtentOnBothAxes() throws {
        _ = NSApplication.shared
        let text = NSAttributedString(string: String(repeating: String(repeating: "x", count: 180) + "\n", count: 200),
                                      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        let measured = TextKit2Layout.measure(text, containerWidth: 0)
        XCTAssertGreaterThan(measured.height, 2500)
        XCTAssertGreaterThan(measured.width, 1200)

        let editor = NSTextView(frame: .zero)
        editor.textStorage?.setAttributedString(text)
        let host = NSHostingView(rootView: TextKit2ScrollSurface(
            attributedString: text, backgroundColor: .black,
            gutter: EditorGutterStyle(width: 48), leadingChromeWidth: 196, trailingChromeWidth: 0,
            sharedTextStorage: editor.textStorage, existingEditor: editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.height, 600)
        XCTAssertGreaterThan(document.frame.height - scroll.contentView.bounds.height, 1500)
        XCTAssertGreaterThan(document.frame.width - scroll.contentView.bounds.width, 400)
        scroll.contentView.scroll(to: NSPoint(x: 250, y: 800))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.minY, 799)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.minX, 249)
    }

    func testHostedEditorKeepsStorageDelegateAndAcceptsEdits() throws {
        _ = NSApplication.shared
        let editor = NSTextView(frame: .zero)
        editor.string = "let value = 1"
        let delegate = EditObserver()
        editor.delegate = delegate
        let storage = try XCTUnwrap(editor.textStorage)
        let oldScrollView = NSScrollView()
        oldScrollView.documentView = editor
        let surface = TextKit2EditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        surface.adopt(editor)
        surface.layoutSubtreeIfNeeded()
        XCTAssertTrue(surface.editorTextView === editor)
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(editor.delegate === delegate)
        XCTAssertNil(oldScrollView.documentView)
        editor.insertText("2", replacementRange: NSRange(location: 12, length: 1))
        XCTAssertEqual(storage.string, "let value = 2")
        XCTAssertGreaterThan(delegate.edits, 0)
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertFalse(editor.textContainer!.widthTracksTextView)
    }

    func testFileBrowserIncludesTemplateAndUnregisteredCodeExtensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["index.html", "page.haml", "script.coffee", "view.coffeehaml",
                     "view.lithaml", "view.chaml", "custom.newlanguage", "Makefile"]
        for name in names {
            try "sample".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let root = FileItem(url: directory, isDirectory: true)
        root.loadChildren()
        XCTAssertEqual(Set(root.children?.map(\.name) ?? []), Set(names))
    }
}

private final class EditObserver: NSObject, NSTextViewDelegate {
    var edits = 0
    func textDidChange(_ notification: Notification) { edits += 1 }
}
