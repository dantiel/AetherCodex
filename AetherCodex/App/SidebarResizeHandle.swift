import SwiftUI

/// A pane-width drag strip, expressed entirely in SwiftUI.
///
/// The four reasons an AppKit `NSView` was once required all have native
/// SwiftUI counterparts, so none of them justifies a representable here:
///
/// | AppKit need | Native SwiftUI |
/// |---|---|
/// | screen-stable drag coordinates | `DragGesture(coordinateSpace: .global)` — the translation is resolved in a space that does not move when the pane resizes, killing the feedback loop that local coordinates would create |
/// | `resetCursorRects` / `NSCursor.resizeLeftRight` | `.pointerStyle(.columnResize)` |
/// | `mouseDownCanMoveWindow = false` | the window's own background-drag policy (`NSWindow.isMovableByWindowBackground` is already `false` for the editor window; a SwiftUI window uses `.windowBackgroundDragBehavior(.disabled)`) |
/// | `acceptsFirstMouse` | *no* public SwiftUI counterpart — the only genuine loss. It matters solely for dragging the strip of an *inactive* window, where the cost is now a single activating click. |
///
/// The strip draws nothing; it exists as a hit target, so `.contentShape`
/// claims the full frame.
struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let limits: ClosedRange<CGFloat>
    /// `1` for a leading pane (drag right widens), `-1` for a trailing one.
    let direction: CGFloat
    let onEnd: (CGFloat) -> Void

    /// Width captured when the drag began; `translation` is applied against it
    /// so a mid-drag relayout of the pane cannot compound into the result.
    @State private var dragStart: CGFloat?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        if dragStart == nil { dragStart = start }
                        width = Self.resizedWidth(start: start,
                                                  delta: value.translation.width,
                                                  direction: direction,
                                                  limits: limits)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onEnd(width)
                    }
            )
    }

    static func resizedWidth(start: CGFloat, delta: CGFloat, direction: CGFloat,
                             limits: ClosedRange<CGFloat>) -> CGFloat {
        min(max(start + delta * direction, limits.lowerBound), limits.upperBound)
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

    /// Width of a pane-resize strip, and the ceiling on it. The strip is
    /// SwiftUI-drawn, but the sidebar's hosted pane is a real `NSView` — and
    /// AppKit hit-tests real subviews before SwiftUI-drawn content. The strip
    /// therefore may never reach past the outer margin it lives in, or the
    /// overlap would go to the pane beneath instead of to the drag. Equal to the
    /// margin, the two meet without overlapping.
    static var resizeStripWidth: CGFloat { trailing }
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