import CoreGraphics

/// Respond to usable window/component space, not a monitor's physical pixels.
/// A little hysteresis prevents flipping repeatedly while dragging the divider.
enum SidebarTabLayout {
    static func isVertical(sidebarWidth: CGFloat, windowWidth: CGFloat, wasVertical: Bool) -> Bool {
        guard windowWidth >= 1100 else { return false }
        return sidebarWidth >= (wasVertical ? 368 : 400)
    }
}
