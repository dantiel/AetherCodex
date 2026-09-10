import AppKit
import SwiftUI

/// Desktop sampling is separate from the SwiftUI in-window scroll-edge effects.
struct WindowBackdrop: NSViewRepresentable {
    let strength: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    func configure(_ view: NSVisualEffectView) {
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = glassMaterial(for: strength)
    }
}
