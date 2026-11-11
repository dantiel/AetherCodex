import AppKit

/// The borderless main-window chrome.
///
/// macOS draws a native window's corner radius and drop shadow inside the window
/// server and exposes no public API for either. Going borderless hands both back:
/// `ShadowRoundedView` clips the content to `EditorChromeMetrics.windowCornerRadius`
/// and paints a matching soft shadow in a transparent rim around it.
final class ShadowRoundedView: NSView {
    /// The rounded content the shadow wraps. Inset by `shadowMargin` on all four
    /// edges so the shadow has room to draw instead of being clipped by the
    /// window's own bounds.
    private(set) var contentView: NSView?

    /// Custom traffic lights, if installed. Positioned over the content frame in
    /// `layout()`; hit-testing is limited to the three dots so the rest of the
    /// title band stays clickable.
    var trafficLights: TrafficLightsView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let trafficLights { addSubview(trafficLights) }
            needsLayout = true
        }
    }

    var cornerRadius: CGFloat = EditorChromeMetrics.windowCornerRadius { didSet { applyGeometry() } }
    var shadowMargin: CGFloat = EditorChromeMetrics.windowShadowMargin { didSet { needsLayout = true } }
    var shadowRadius: CGFloat = EditorChromeMetrics.windowShadowRadius { didSet { applyGeometry() } }
    var shadowOpacity: Float = EditorChromeMetrics.windowShadowOpacity { didSet { applyGeometry() } }
    var shadowOffset: NSSize = NSSize(width: 0, height: -EditorChromeMetrics.windowShadowOffsetY) {
        didSet { applyGeometry() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The visible-content rect: the window bounds minus the shadow rim.
    var contentFrame: CGRect { bounds.insetBy(dx: shadowMargin, dy: shadowMargin) }

    func embed(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        applyGeometry()
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    private func applyGeometry() {
        guard let layer else { return }
        let frame = contentFrame
        layer.shadowPath = CGPath(roundedRect: frame,
                                  cornerWidth: cornerRadius,
                                  cornerHeight: cornerRadius,
                                  transform: nil)
        layer.shadowRadius = shadowRadius
        layer.shadowOpacity = shadowOpacity
        layer.shadowOffset = shadowOffset
        layer.shadowColor = NSColor.black.cgColor
        contentView?.frame = frame
        contentView?.layer?.cornerRadius = cornerRadius
        contentView?.layer?.masksToBounds = true
        trafficLights?.frame = frame
    }
}

/// System-drawn controls hosted over our custom window silhouette.
final class TrafficLightsView: NSView {
    enum Kind: Int { case close, minimize, zoom }
    var onAction: ((Kind) -> Void)?
    private(set) var buttons: [NSButton] = []
    var leadingInset: CGFloat = 20 { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: style) else { continue }
            // Keep the factory's intrinsic size, cell, glyphs and press tracking.
            button.tag = index
            button.target = self
            button.action = #selector(activate(_:))
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var x = leadingInset
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: x, y: 30 - button.frame.height / 2))
            x += button.frame.width + 6
        }
    }

    // Leave tracking and event dispatch to AppKit. Never forward mouseEntered /
    // mouseExited to child buttons: their responder chain can send the event
    // straight back here, causing unbounded recursion (crash 2026-10-27).

    @objc private func activate(_ sender: NSButton) {
        guard let kind = Kind(rawValue: sender.tag) else { return }
        onAction?(kind)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, alphaValue > 0 else { return nil }
        for button in buttons where button.frame.contains(local) {
            return button.hitTest(local)
        }
        return nil
    }
}
