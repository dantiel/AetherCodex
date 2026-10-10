import AppKit
import XCTest
@testable import AetherCodex

final class EditorPaddingTests: XCTestCase {
    func testSelectionContinuesThroughPaddingWithoutExtendingPartialFirstLine() {
        let selection = NSRange(location: 3, length: 12)
        XCTAssertFalse(HighlightingLayoutManager.selectionCoversLeadingEdge(selection, lineStart: 0))
        XCTAssertTrue(HighlightingLayoutManager.selectionCoversLeadingEdge(selection, lineStart: 6))
        XCTAssertTrue(HighlightingLayoutManager.selectionCoversLeadingEdge(selection, lineStart: 12))
        XCTAssertFalse(HighlightingLayoutManager.selectionCoversLeadingEdge(selection, lineStart: 15))
        XCTAssertFalse(HighlightingLayoutManager.selectionCoversLeadingEdge(NSRange(location: 6, length: 0), lineStart: 6))
        XCTAssertTrue(HighlightingLayoutManager.selectionCoversLeadingEdge(NSRange(location: 0, length: 1), lineStart: 0))
    }

    @MainActor func testAdoptedEditorKeepsTenPointTextInset() {
        _ = NSApplication.shared
        let editor = NSTextView()
        let host = TextKit2EditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.adopt(editor)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.textContainerInset.width, 10)
        XCTAssertEqual(editor.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(editor.textContainerInset.height, 0)
    }
}
