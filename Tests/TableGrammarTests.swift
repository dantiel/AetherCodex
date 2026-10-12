import AppKit
import XCTest
@testable import AetherCodex

/// One grammar, two renderers — asserted, not assumed.
///
/// The SwiftUI oracle surface is checked by geometry (a table wraps and never
/// outgrows its host); the editable AppKit surface is checked by reading the
/// widths straight back off its `NSTextTableBlock`s *and* by laying a cell out, so
/// that "stored" and "honoured" are never confused. Both must agree with
/// `MarkdownTableStyle`.
@MainActor
final class TableGrammarTests: XCTestCase {
    // MARK: - The AppKit surface, read back

    private func blocks(_ rows: [[String]]) -> [NSTextTableBlock] {
        let table = RichTextTable.make(rows)
        var found: [NSTextTableBlock] = []
        table.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: table.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return }
            guard !found.contains(where: { $0.startingRow == block.startingRow && $0.startingColumn == block.startingColumn }) else { return }
            found.append(block)
        }
        return found
    }

    /// Lays a single cell out and reports the height the layout manager used — the
    /// only honest witness that a per-edge width reached the page rather than the
    /// property.
    private func laidOutHeight(padding: CGFloat, border: CGFloat) -> CGFloat {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = true   // as `RichTextTable` builds it
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        for edge in [NSRectEdge.minY, .maxY] {
            block.setWidth(padding, type: .absoluteValueType, for: .padding, edge: edge)
            block.setWidth(border, type: .absoluteValueType, for: .border, edge: edge)
        }
        block.setBorderColor(MarkdownTableStyle.border)
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        let cell = NSMutableAttributedString(string: "Zelle\n", attributes: [
            .font: MarkdownRichCodec.font(level: 0), .paragraphStyle: paragraph,
        ])
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 2000))
        view.textStorage?.setAttributedString(cell)
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        return layout.usedRect(for: view.textContainer!).height
    }

    func testPaddingMatchesTheOracleSurface() {
        _ = NSApplication.shared
        let all = blocks([["H1", "H2"], ["a", "b"]])
        XCTAssertEqual(all.count, 4, "every cell must carry its own block")
        for block in all {
            XCTAssertEqual(block.width(for: .padding, edge: .minX), MarkdownTableStyle.cellPaddingH)
            XCTAssertEqual(block.width(for: .padding, edge: .maxX), MarkdownTableStyle.cellPaddingH)
            XCTAssertEqual(block.width(for: .padding, edge: .minY), MarkdownTableStyle.cellPaddingV)
            XCTAssertEqual(block.width(for: .padding, edge: .maxY), MarkdownTableStyle.cellPaddingV)
        }
    }

    func testLineGrammarMatchesTheOracleSurface() {
        _ = NSApplication.shared
        let all = blocks([["H1", "H2"], ["a", "b"], ["c", "d"]])
        let width = MarkdownTableStyle.borderWidth
        func block(_ row: Int, _ column: Int) -> NSTextTableBlock {
            all.first { $0.startingRow == row && $0.startingColumn == column }!
        }

        // Column hairlines: the table's left rim, then a line after every column.
        XCTAssertEqual(block(0, 0).width(for: .border, edge: .minX), width)
        XCTAssertEqual(block(0, 1).width(for: .border, edge: .minX), 0)
        XCTAssertEqual(block(1, 0).width(for: .border, edge: .maxX), width)
        XCTAssertEqual(block(1, 1).width(for: .border, edge: .maxX), width)

        // Rim: the header opens the table, the last row closes it.
        XCTAssertEqual(block(0, 0).width(for: .border, edge: .minY), width)
        XCTAssertEqual(block(0, 1).width(for: .border, edge: .maxY), width)
        XCTAssertEqual(block(2, 0).width(for: .border, edge: .maxY), width)

        // The header rule — and no horizontal grid inside the body.
        XCTAssertTrue(MarkdownTableStyle.headerRule)
        XCTAssertFalse(MarkdownTableStyle.rowRules)
        XCTAssertTrue(MarkdownTableStyle.columnRules)
        XCTAssertEqual(block(1, 0).width(for: .border, edge: .minY), 0)
        XCTAssertEqual(block(1, 0).width(for: .border, edge: .maxY), 0)
    }

    /// Storing a width is not the same as *honouring* it: a per-edge padding that
    /// never reaches the layout manager would be correspondence on paper only.
    func testPerEdgePaddingIsHonouredByLayout() {
        _ = NSApplication.shared
        XCTAssertEqual(laidOutHeight(padding: MarkdownTableStyle.cellPaddingV, border: 0) - laidOutHeight(padding: 0, border: 0),
                       2 * MarkdownTableStyle.cellPaddingV, accuracy: 1)
    }

    /// And the same for the border layer — otherwise the header rule and the
    /// deliberately absent body grid would never reach the page.
    func testPerEdgeBorderIsHonouredByLayout() {
        _ = NSApplication.shared
        let delta = laidOutHeight(padding: 0, border: MarkdownTableStyle.borderWidth) - laidOutHeight(padding: 0, border: 0)
        XCTAssertGreaterThan(delta, 0, "a per-edge border the layout manager ignores would never reach the page")
        XCTAssertEqual(delta, 2 * MarkdownTableStyle.borderWidth, accuracy: 0.6,
                       "observed: `NSTextTable` reserves each edge stroke twice in its bounds math")
    }

    /// A multi-line cell must grow its row. This is the defect the oracle surface
    /// suffered (every row pinned to one clipped line); the editable surface wraps
    /// natively, so its row height must exceed a single line plus its padding — and
    /// the table must never outgrow the container that hosts it.
    func testMultiLineCellGrowsTheRow() {
        _ = NSApplication.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 2000))
        view.textStorage?.setAttributedString(
            RichTextTable.make([["Header"], ["erste Zeile\nzweite Zeile\ndritte Zeile"]])
        )
        let layout = try! XCTUnwrap(view.layoutManager)
        let container = try! XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        XCTAssertLessThanOrEqual(used.width, 340.5, "a table must not outgrow its container")
        XCTAssertGreaterThan(used.height, CGFloat(3) * MarkdownTableStyle.cellPaddingV,
                             "the row must grow with its tallest cell")
    }
}