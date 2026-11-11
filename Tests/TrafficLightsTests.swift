import AppKit
import XCTest
@testable import AetherCodex

@MainActor
final class TrafficLightsTests: XCTestCase {
    func testHoverDoesNotReenterChildResponders() throws {
        let lights = TrafficLightsView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        lights.layoutSubtreeIfNeeded()
        lights.updateTrackingAreas()
        XCTAssertEqual(lights.buttons.count, 3)
        XCTAssertTrue(lights.trackingAreas.isEmpty, "The host must not synthesize group hover events")
        for type in [NSEvent.EventType.mouseEntered, .mouseExited] {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: type,
                location: NSPoint(x: 24, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))
            // Native controls may forward these to their parent. Previously
            // the parent dispatched them back to every child indefinitely.
            if type == .mouseEntered {
                lights.mouseEntered(with: event)
            } else {
                lights.mouseExited(with: event)
            }
        }
    }
}
