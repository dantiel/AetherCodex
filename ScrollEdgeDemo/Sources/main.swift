import Cocoa

// ── ScrollEdgeDemo — Content Fade + Behind-Window Glass ──
// macOS 26.3, SDK 26.2
//
// Strategy:
//   1. NSVisualEffectView (.behindWindow) sits behind everything — blurs desktop
//   2. CAGradientLayer mask on the NSScrollView fades TOP content to transparent
//   3. Transparent content reveals the desktop-blur glass behind
//
//   Result: text fades/blurs progressively as it scrolls under the toolbar.
//   This is the standard macOS pattern for unified-toolbar apps.

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scrollView: NSScrollView!
    let fadeHeight: CGFloat = 100

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── Content View (filled by window) ──
        let contentView = NSView(frame: .zero)
        contentView.wantsLayer = true

        // ── Behind-window glass: .behindWindow samples desktop content ──
        let glassBg = NSVisualEffectView(frame: .zero)
        glassBg.material = .titlebar
        glassBg.blendingMode = .behindWindow
        glassBg.state = .active
        glassBg.autoresizingMask = [.width, .height]
        contentView.addSubview(glassBg, positioned: .below, relativeTo: nil)

        // ── ScrollView ──
        scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.autoresizingMask = [.width, .height]

        // ── Text View with colorful content ──
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)

        let content = NSMutableAttributedString()
        for i in 0..<200 {
            let hue = CGFloat(i % 20) / 20.0
            let color = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
            let line = NSAttributedString(
                string: "Line \(i) — Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n",
                attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
            )
            content.append(line)
        }
        textView.textStorage?.setAttributedString(content)
        scrollView.documentView = textView

        contentView.addSubview(scrollView)

        // ── Apply fade mask AFTER scrollView is laid out ──
        DispatchQueue.main.async { [weak self] in
            self?.applyFadeMask()
        }

        // ── Window ──
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                      .fullSizeContentView, .unifiedTitleAndToolbar],
                          backing: .buffered, defer: false)
        window.title = "ScrollEdgeDemo — Content Fade + Glass"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentView = contentView

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func applyFadeMask() {
        guard scrollView.bounds.height > 0 else { return }

        let mask = CAGradientLayer()
        mask.frame = scrollView.bounds

        // Top: transparent (reveals glass) → Bottom: opaque (shows content)
        mask.colors = [
            CGColor.clear,     // y=0: fully transparent → glass visible
            CGColor.black,     // fade zone ends
            CGColor.black      // rest: fully opaque content
        ]
        mask.locations = [0.0,
                          NSNumber(value: Float(fadeHeight / scrollView.bounds.height)),
                          1.0]
        mask.startPoint = CGPoint(x: 0.5, y: 0.0)  // top
        mask.endPoint   = CGPoint(x: 0.5, y: 1.0)  // bottom

        scrollView.layer?.mask = mask

        // Track bounds changes to keep mask in sync
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            mask.frame = self.scrollView.bounds
            mask.locations = [0.0,
                              NSNumber(value: Float(self.fadeHeight / self.scrollView.bounds.height)),
                              1.0]
        }

        NSLog("Fade mask applied: frame=\(mask.frame), fadeHeight=\(fadeHeight), scrollHeight=\(scrollView.bounds.height)")
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()