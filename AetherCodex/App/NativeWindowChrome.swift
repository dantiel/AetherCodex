import AppKit

/// Preserve native toolbar compositing, window rounding and traffic lights.
/// SwiftUI owns the populated toolbar and the scroll views' soft edge effects.
enum NativeWindowChrome {
    @MainActor
    static func configure(_ window: NSWindow) {
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false

        // Do not hide titlebar NSVisualEffectViews or private backdrop layers.
        // They are system-owned compositing resources, not just decorative fill.
        // Hiding a material's parent can also hide native edge effects. No
        // deferred hierarchy traversal may disable them after layout.
    }

    /// The window server owns the silhouette, including after live resize.
    @MainActor
    static func updateSilhouette(_ window: NSWindow) {}
}
