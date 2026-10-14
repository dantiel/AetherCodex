import AppKit
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit

/// The raw privilege primitives — the *only* place in the whole codebase that
/// touches TCC-gated APIs. Everything flows through the shield.
///
/// Screen Recording, Accessibility and Automation consent are keyed by macOS to
/// the requesting process's code signature. AetherAegis is signed with a stable
/// identity (see `make_aegis_cert.sh`), so these grants persist; AetherCodex is
/// rebuilt constantly and never needs them, because it never touches these APIs
/// directly — it asks the shield.
enum Privileges {
    // MARK: Screen Recording

    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Accessibility

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return AXIsProcessTrusted()
    }

    // MARK: Automation (Apple Events)

    /// Automation consent has no public query API. A benign probe to System
    /// Events is the honest signal: it triggers the consent dialog once and
    /// returns true on subsequent calls once granted.
    @discardableResult
    static func requestAppleEvents() -> Bool {
        let script = NSAppleScript(source: "tell application \"System Events\" to get name of first process")
        var err: NSDictionary?
        let result = script?.executeAndReturnError(&err)
        return result != nil && err == nil
    }

    // MARK: Screen capture

    /// Capture the primary display as PNG-encoded data. Requires Screen
    /// Recording; returns nil (without prompting) when not yet granted.
    ///
    /// Uses ScreenCaptureKit — `CGWindowListCreateImage` is obsoleted on macOS
    /// 15+, so the shield captures through the modern path.
    static func capturePrimaryScreen() async -> Data? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = true

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .png, properties: [:])
        } catch {
            return nil
        }
    }
}