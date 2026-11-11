import SwiftUI
import AppKit

/// Progressive blur for the edge of a scroll surface.
///
/// macOS 26's `scrollEdgeEffectStyle` only paints against a *pinned* control:
/// a `safeAreaBar` whose content is `Color.clear` gives the edge compositor
/// nothing to blend with, so the code column never showed an edge blur even
/// with the style and the bar in place.
///
/// This view builds the ramp explicitly: one `NSVisualEffectView` with
/// `.withinWindow` blending — it samples the window's own content, so the code
/// passing beneath the band softens instead of showing the desktop through it —
/// whose material is alpha-shaped by a vertical gradient mask. The band is the
/// empty chrome row a `safeAreaBar` reserves; the blur is what fills it.
///
/// The ramp is concentrated at the locked edge (a couple of points of near-full
/// blur) and dies out before the band's far side, which is what makes it read as
/// the text dissolving into the chrome rather than as a frosted strip.
struct ScrollEdgeBlur: View {
    enum Edge { case top, bottom }

    var edge: Edge = .top
    /// Length of the ramp in points — the band the blur occupies.
    var length: CGFloat

    var body: some View {
        WithinWindowBlur()
            .frame(maxWidth: .infinity)
            .frame(height: max(length, 1))
            .compositingGroup()
            .mask(ramp)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var ramp: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.58), location: 0.16),
                .init(color: .white.opacity(0.22), location: 0.44),
                .init(color: .white.opacity(0.06), location: 0.74),
                .init(color: .clear, location: 1)
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }
}

/// `NSVisualEffectView` in `.withinWindow` mode.
///
/// `.behindWindow` would sample the desktop (the window is non-opaque); the
/// `.withinWindow` material frosts what is drawn behind it in this window,
/// which is exactly the scrolled code.
private struct WithinWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
