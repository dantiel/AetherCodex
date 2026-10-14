import SwiftUI
import XCTest
@testable import AetherCodex

/// Panel geometry, pinned where it is structural.
///
/// Two invariants that used to be exercised through AppKit — that a pane drag
/// never moves the window, and that the resize strip outranks the pane beneath
/// it — no longer have an `NSView` to test against. They moved, so the tests
/// move: the window is made non-background-draggable once, at its single
/// construction site; the strip's priority is now guaranteed by *geometry* and
/// pinned by `testResizeStripNeverReachesBeneathTheHostedSidebar`.
@MainActor
final class SidebarLayoutTests: XCTestCase {
    func testRestoredPanelWidthsLeaveRoomForEditor() {
        for width in [800.0, 1024, 1640] {
            let layout = EditorPanelWidths(available: width, sidebar: 900, inspector: 900)
            XCTAssertGreaterThanOrEqual(width - layout.leading - layout.trailing, 320)
            XCTAssertLessThanOrEqual(layout.leading, 544)
            XCTAssertLessThanOrEqual(layout.trailing, 640)
            XCTAssertGreaterThanOrEqual(layout.leading, 196)
        }
        let collapsed = EditorPanelWidths(available: 800, sidebar: nil, inspector: nil)
        XCTAssertEqual(collapsed.leading, 0)
        XCTAssertEqual(collapsed.trailing, 0)
    }
    func testSheetHasActualOuterMarginsAtEverySupportedWidth() {
        for width in [180.0, 220, 350, 520] {
            let bounds = CGSize(width: SidebarSheetGeometry.containerWidth(for: width),
                                height: 600)
            let frame = SidebarSheetGeometry.frame(in: bounds)
            XCTAssertEqual(frame.width, width)
            XCTAssertEqual(frame.minX, 8)
            XCTAssertEqual(bounds.width - frame.maxX, 8)
            XCTAssertEqual(frame.minY, 8)
            XCTAssertEqual(bounds.height - frame.maxY, 8)
        }
    }

    func testBothResizeDirectionsAndLimits() {
        XCTAssertEqual(SidebarResizeHandle.resizedWidth(start: 220, delta: 30,
                         direction: 1, limits: 180...520), 250)
        XCTAssertEqual(SidebarResizeHandle.resizedWidth(start: 280, delta: -30,
                         direction: -1, limits: 220...640), 310)
        XCTAssertEqual(SidebarResizeHandle.resizedWidth(start: 220, delta: -500,
                         direction: 1, limits: 180...520), 180)
        XCTAssertEqual(SidebarResizeHandle.resizedWidth(start: 280, delta: -1000,
                         direction: -1, limits: 220...640), 640)
    }

    /// The load-bearing geometry of the drag strip. The sidebar's hosted pane is
    /// a real `NSView` inset by `SidebarSheetGeometry` on both sides, and AppKit
    /// hit-tests real subviews before SwiftUI-drawn content. The strip is drawn
    /// by SwiftUI — so if it reached beneath the pane it would lose exactly that
    /// overlap to the file browser, and the drag would start only in the sliver
    /// left over. Equal widths make the two meet, never overlap.
    func testResizeStripNeverReachesBeneathTheHostedSidebar() {
        for sheetWidth in [180.0, 220, 350, 520] {
            let container = SidebarSheetGeometry.containerWidth(for: sheetWidth)
            let sheet = SidebarSheetGeometry.frame(in: CGSize(width: container, height: 600))
            let stripMinX = container - SidebarSheetGeometry.resizeStripWidth
            XCTAssertGreaterThanOrEqual(
                stripMinX, sheet.maxX,
                "strip reaches \(sheet.maxX - stripMinX)pt beneath the sidebar's hosted content"
            )
        }
    }

    /// The drag is resolved against the width captured at gesture start, never
    /// against the pane's current width. That is what keeps a mid-drag relayout —
    /// SwiftUI re-placing the strip as the pane widens — from compounding into
    /// the result: the same translation always yields the same width.
    func testDragTranslationIsAbsoluteNotIncremental() {
        let start: CGFloat = 220
        let width = SidebarResizeHandle.resizedWidth(start: start, delta: 264 - 224,
                                                     direction: 1, limits: 180...520)
        XCTAssertEqual(width, 260)
        XCTAssertEqual(SidebarResizeHandle.resizedWidth(start: start, delta: 264 - 224,
                                                        direction: 1, limits: 180...520),
                       width)
    }
}