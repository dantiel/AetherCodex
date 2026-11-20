import AppKit
import XCTest
@testable import AetherCodex

@MainActor
final class NativeWindowChromeTests: XCTestCase {
    func testConfigurationPreservesSystemButtonsAndActions() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let toolbar = NSToolbar(identifier: "NativeWindowChromeTests")
        window.toolbar = toolbar
        let buttons = try types.map { try XCTUnwrap(window.standardWindowButton($0)) }
        let actions = buttons.map(\.action)
        let parents = buttons.map(\.superview)
        let targets = buttons.map { $0.target as AnyObject? }
        NativeWindowChrome.configure(window)
        for (index, type) in types.enumerated() {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertTrue(button === buttons[index])
            XCTAssertEqual(button.action, actions[index])
            XCTAssertNotNil(button.superview)
            XCTAssertTrue(button.superview === parents[index])
            XCTAssertTrue((button.target as AnyObject?) === targets[index])
        }
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.hasShadow)
        // Full-size content behind the titlebar, transparent background, and the
        // window server owns the unified corner radius (no manual content clip).
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.toolbarStyle, .unified)
        // The radius toolbar must be ATTACHED: `toolbarStyle` alone is inert and
        // the window server keeps the small "plain" radius without it.
        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        // The window server rounds the window; the content view must NOT
        // carry a second, conflicting radius.
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.layer?.cornerRadius ?? 0, 0)
        XCTAssertFalse(content.layer?.masksToBounds ?? false)
        window.setContentSize(NSSize(width: 900, height: 650))
        NativeWindowChrome.updateSilhouette(window)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(content.layer?.cornerRadius ?? 0, 0)
    }

    func testConfigurationPreservesToolbarMaterialAfterResizeAndDeferredLayout() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        let frame = try XCTUnwrap(window.contentView?.superview)
        let material = NSVisualEffectView(frame: NSRect(x: 0, y: 550, width: 800, height: 50))
        material.material = .headerView
        material.wantsLayer = true
        frame.addSubview(material)
        defer { material.removeFromSuperview() }

        NativeWindowChrome.configure(window)
        XCTAssertFalse(material.isHidden)
        XCTAssertFalse(material.layer?.isHidden ?? false)
        window.setContentSize(NSSize(width: 950, height: 700))
        NativeWindowChrome.updateSilhouette(window)
        // The old implementation hid materials repeatedly for two seconds.
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertFalse(material.isHidden)
        XCTAssertFalse(material.layer?.isHidden ?? false)
    }
}
