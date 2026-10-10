import XCTest
@testable import AetherCodex

final class SidebarTabLayoutTests: XCTestCase {
    func testNarrowSidebarNeverSpendsWidthOnRail() {
        XCTAssertFalse(SidebarTabLayout.isVertical(sidebarWidth: 180, windowWidth: 2500, wasVertical: false))
        XCTAssertFalse(SidebarTabLayout.isVertical(sidebarWidth: 320, windowWidth: 1400, wasVertical: true))
    }
    func testCompactWindowUsesHeaderEvenWithWideSidebar() {
        XCTAssertFalse(SidebarTabLayout.isVertical(sidebarWidth: 500, windowWidth: 900, wasVertical: true))
    }
    func testWideLayoutAndResizeHysteresis() {
        XCTAssertTrue(SidebarTabLayout.isVertical(sidebarWidth: 420, windowWidth: 1400, wasVertical: false))
        XCTAssertTrue(SidebarTabLayout.isVertical(sidebarWidth: 380, windowWidth: 1400, wasVertical: true))
        XCTAssertFalse(SidebarTabLayout.isVertical(sidebarWidth: 380, windowWidth: 1400, wasVertical: false))
        XCTAssertFalse(SidebarTabLayout.isVertical(sidebarWidth: 360, windowWidth: 1400, wasVertical: true))
    }
}
