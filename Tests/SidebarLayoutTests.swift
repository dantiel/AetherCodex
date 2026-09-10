import AppKit
import SwiftUI
import XCTest
@testable import AetherCodex

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
        XCTAssertEqual(SidebarResizeView.resizedWidth(start: 220, delta: 30,
                         direction: 1, limits: 180...520), 250)
        XCTAssertEqual(SidebarResizeView.resizedWidth(start: 280, delta: -30,
                         direction: -1, limits: 220...640), 310)
        XCTAssertEqual(SidebarResizeView.resizedWidth(start: 220, delta: -500,
                         direction: 1, limits: 180...520), 180)
        XCTAssertEqual(SidebarResizeView.resizedWidth(start: 280, delta: -1000,
                         direction: -1, limits: 220...640), 640)
    }

    func testNativeMouseDragResizesWithoutMovingWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Deliberately enable the old problematic setting: the handle must
        // still claim its events rather than moving the window.
        window.isMovableByWindowBackground = true
        let handle = SidebarResizeView(frame: CGRect(x: 220, y: 0, width: 12, height: 600))
        window.contentView?.addSubview(handle)
        defer { window.close() }

        XCTAssertFalse(handle.mouseDownCanMoveWindow)
        XCTAssertTrue(handle.acceptsFirstMouse(for: nil))
        let windowFrame = window.frame
        var changes: [CGFloat] = []
        var committed: CGFloat?
        handle.onChange = { changes.append($0) }
        handle.onEnd = { committed = $0 }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 100),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try event(.leftMouseDown, x: 224))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 254))
        // Simulate SwiftUI relocating the resize strip after updating the width.
        handle.setFrameOrigin(CGPoint(x: 250, y: 0))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 264))
        handle.mouseUp(with: try event(.leftMouseUp, x: 264))
        XCTAssertEqual(changes, [250, 260, 260])
        XCTAssertEqual(committed, 260)
        XCTAssertEqual(window.frame, windowFrame)
    }

    func testResizeStripReceivesHitsAboveHostedAppKitContent() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView:
            ZStack(alignment: .trailing) {
                AppKitViewHost { NSView() }
                SidebarResizeHandle(width: .constant(220), limits: 180...520,
                                    direction: 1, onEnd: { _ in })
                    .frame(width: 12)
            }
        )
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 220, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 220, height: 300)
        host.layoutSubtreeIfNeeded()
        let hit = host.hitTest(CGPoint(x: 214, y: 150))
        XCTAssertTrue(hit is SidebarResizeView, "Resize strip must own its mouse events, got \(String(describing: hit))")
    }
}
