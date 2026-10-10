import AppKit
import SwiftUI

/// A real mouse target: never delegates a resize drag to window-background dragging.
final class SidebarResizeView: NSView {
    var width: CGFloat = 220
    var limits: ClosedRange<CGFloat> = 180...520
    var direction: CGFloat = 1
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat) -> Void = { _ in }
    private var dragStart: (screenX: CGFloat, width: CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    static func resizedWidth(start: CGFloat, delta: CGFloat, direction: CGFloat,
                             limits: ClosedRange<CGFloat>) -> CGFloat {
        min(max(start + delta * direction, limits.lowerBound), limits.upperBound)
    }

    private func screenX(for event: NSEvent) -> CGFloat {
        window?.convertPoint(toScreen: event.locationInWindow).x ?? event.locationInWindow.x
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (screenX(for: event), width)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        // Screen coordinates remain stable when SwiftUI moves this handle as
        // the column changes width. Local coordinates would create feedback.
        width = Self.resizedWidth(start: start.width,
                                  delta: screenX(for: event) - start.screenX,
                                  direction: direction, limits: limits)
        onChange(width)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        mouseDragged(with: event)
        dragStart = nil
        onEnd(width)
        window?.invalidateCursorRects(for: self)
    }
}

struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let limits: ClosedRange<CGFloat>
    let direction: CGFloat
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarResizeView {
        let view = SidebarResizeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SidebarResizeView, context: Context) {
        view.width = width
        view.limits = limits
        view.direction = direction
        view.onChange = { width = $0 }
        view.onEnd = onEnd
    }
}

enum SidebarSheetGeometry {
    static let leading: CGFloat = 8
    static let trailing: CGFloat = 8
    static let vertical: CGFloat = 8
    static var horizontalInsets: CGFloat { leading + trailing }

    /// `sidebarWidth` denotes the usable sheet width. The safe-area column is
    /// wider because it also owns the requested outer window margins.
    static func containerWidth(for sheetWidth: CGFloat) -> CGFloat {
        max(0, sheetWidth) + horizontalInsets
    }

    static func frame(in size: CGSize) -> CGRect {
        CGRect(x: leading, y: vertical,
               width: max(0, size.width - leading - trailing),
               height: max(0, size.height - 2 * vertical))
    }

    /// Height of the floating tab-bar band docked to the sheet's lower edge. The
    /// `sidebarTabBar` modifier gives the bar exactly this height, so each pane's
    /// scroller insets its own content by the same measure — the last row clears
    /// the capsule while the content still travels *behind* it.
    static let tabBarBand: CGFloat = 48
}

/// The canvas and both safe-area bars share exactly these widths. Reserve a
/// usable editor when restoring oversized preferences or narrowing the window.
struct EditorPanelWidths {
    let leading: CGFloat
    let trailing: CGFloat
    let sidebarMaximum: CGFloat
    let inspectorMaximum: CGFloat

    init(available: CGFloat, sidebar: CGFloat?, inspector: CGFloat?) {
        let budget = max(0, available - 320)
        let margin = SidebarSheetGeometry.horizontalInsets
        let minimumLeading: CGFloat = sidebar == nil ? 0 : 180 + margin
        let rightLimit = max(220, min(640, budget - minimumLeading))
        trailing = inspector.map { min(max($0, 220), rightLimit) } ?? 0
        sidebarMaximum = max(180, min(520, budget - trailing - margin))
        if let sidebar {
            leading = min(max(sidebar, 180), sidebarMaximum) + margin
        } else {
            leading = 0
        }
        inspectorMaximum = max(220, min(640, budget - leading))
    }
}