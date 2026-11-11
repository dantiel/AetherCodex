import AppKit

/// Native window chrome for the main window.
///
/// The main window is a **titled** window (`.windowStyle(.titleBar)`, declared
/// by `AetherCodexApp.body`) carrying a **populated** unified `NSToolbar` — the
/// one SwiftUI builds from `.toolbar { }` on the scene content. macOS only
/// renders the modern continuous corner radius when the window *owns* a
/// populated toolbar; `toolbarStyle` alone is inert. The toolbar also hosts the
/// clickable title-row controls (sidebar toggle, title, editor-mode switches,
/// Pythia pair), so no click-blocking empty toolbar band is left over the
/// full-bleed content.
///
/// Invariants this type must never violate:
///
/// 1. The window stays **non-opaque** with a **clear** background. The unified
///    corner radius comes from the *populated* toolbar (the window server rounds
///    a toolbar-bearing titled window), not from opacity — so a clear window
///    costs nothing here and lets the titlebar/toolbar draw no material of their
///    own. The content view must carry **no** second radius (`cornerRadius == 0`,
///    `masksToBounds == false`).
///
/// 2. `fullSizeContentView` + transparent titlebar keep the editor's glass
///    full-bleed behind the traffic lights; the content ignores the top safe
///    area, so the full-bleed sidebars ride under the toolbar and their sheets
///    shift down by `EditorChromeMetrics.titleBarBand` to clear it.
enum NativeWindowChrome {

    @MainActor
    static func configure(_ window: NSWindow) {
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isMovableByWindowBackground = false

        // Transparent titlebar: content bleeds behind the native traffic lights.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Transparent window: the titlebar and unified toolbar draw no material
        // of their own, so the editor's glass bleeds up behind the traffic
        // lights. The *populated* toolbar (not opacity) is what flips the window
        // server into the unified corner-radius path, so clearing the background
        // here costs nothing.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // No hairline between titlebar and content: the toolbar band must read
        // as *nothing*, not as system chrome.
        window.titlebarSeparatorStyle = .none

        // The toolbar is owned by SwiftUI (`.toolbar { }` on the scene content).
        // A *populated* toolbar is what flips the window server into the unified
        // corner-radius path AND hosts the clickable title-row controls — an
        // item-less toolbar would still reserve a click-blocking titlebar band.
        // We only pin the unified style; SwiftUI supplies the items.
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        hideTitlebarMaterial(window)
        // SwiftUI installs its toolbar — and the AppKit titlebar's material —
        // a beat *after* the window is adopted, and re-asserts it again once
        // the first toolbar pass has run. Re-apply over the first two seconds;
        // the layers are idempotent to hide.
        for delay in [0.0, 0.05, 0.25, 0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window = window else { return }
                window.titleVisibility = .hidden
                window.toolbar?.showsBaselineSeparator = false
                hideTitlebarMaterial(window)
            }
        }
    }

    /// Strip every material view behind the native titlebar/toolbar.
    ///
    /// `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` is the
    /// SwiftUI switch, but macOS 26 still lets the AppKit titlebar container
    /// keep an `NSVisualEffectView` behind a populated toolbar — and because the
    /// window is non-opaque it samples the *desktop*, reading as a glass strip
    /// above the editor. Hiding those views is the only deterministic way to
    /// make the toolbar literally transparent, so the editor's own glass (and
    /// the code surface's top scroll-edge blur) show through it.
    ///
    /// Only the frame view's siblings of the content view are touched — the
    /// content hierarchy (editor glass, sidebars) is never walked.
    @MainActor
    static func hideTitlebarMaterial(_ window: NSWindow) {
        guard let content = window.contentView, let frame = content.superview else { return }
        for view in frame.subviews where view !== content {
            hideVisualEffectViews(in: view)
        }
    }

    private static func hideVisualEffectViews(in view: NSView) {
        // Only the *titlebar backdrop* materials are touched. SwiftUI draws the
        // per-item glass (`.ultraThinMaterial` pills, menus) with other
        // materials; hiding those would blank our own toolbar controls.
        if let effect = view as? NSVisualEffectView,
           effect.material == .titlebar || effect.material == .headerView {
            effect.isHidden = true
            return
        }
        // The AppKit title view keeps drawing the window title (and its own
        // glass capsule) even with `titleVisibility = .hidden`, centred over
        // the bar — a second, unclickable title beside our toolbar item.
        if String(describing: type(of: view)).contains("ToolbarTitleView") {
            view.isHidden = true
            return
        }
        // macOS 26 draws the unified toolbar's glass as a bare view whose own
        // layer is a `CABackdropLayer` (a private class no material switch
        // reaches) and as backdrop layers inside the titlebar containers. Both
        // make the bar read as glass over the non-opaque window, so they are
        // hidden at the layer level — the window server still rounds the
        // window, the bar just stops drawing.
        if let layer = view.layer {
            if isBackdrop(layer) { layer.isHidden = true }
            for sub in layer.sublayers ?? [] where isBackdrop(sub) { sub.isHidden = true }
        }
        for subview in view.subviews { hideVisualEffectViews(in: subview) }
    }

    /// Backdrop layers are the window server's material carriers; the class is
    /// private, so match it by name instead of linking against it.
    private static func isBackdrop(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)) == "CABackdropLayer"
    }

    /// No-op. The window server rounds the opaque window itself; there is no
    /// manual silhouette to re-assert. Kept so the callers (resize, fullscreen
    /// enter/exit, key-status) share one seam.
    @MainActor
    static func updateSilhouette(_ window: NSWindow) {}
}