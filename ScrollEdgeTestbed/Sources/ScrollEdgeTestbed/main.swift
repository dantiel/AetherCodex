import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)  // unbuffered stdout for log capture

// ── ScrollEdge Testbed ──────────────────────────────────────────────
// Usage:  .build/debug/ScrollEdgeTestbed -variant plain|accessory|splititem
//   plain     — unified toolbar + fullSizeContentView, scroll view pinned
//               to all 4 edges of contentView. No accessory.
//               automaticallyAdjustsContentInsets = TRUE (the default —
//               the system tracks the overlapping titlebar and applies
//               the native scroll-edge effect). Title VISIBLE.
//   accessory — window-level NSTitlebarAccessoryViewController (.bottom,
//               .soft, 44pt plain label view — NO glass material).
//   splititem — NSSplitViewController wrapper + split-item top accessory
//               (.soft, 44pt plain red view — NO glass material).
// Every variant: bright-blue NSTextView, white 18pt monospaced text,
// 300 lines, auto-scrolled 400pt down. Geometry + ancestor-clip log.

let variant = UserDefaults.standard.string(forKey: "variant") ?? "plain"
// Production-trait toggles for the prodlike variant (each ON by default,
// flip OFF with -noopaque / -nomaterial / -nolayer / -notitle)
let noOpaque   = UserDefaults.standard.bool(forKey: "noopaque")
let noMaterial = UserDefaults.standard.bool(forKey: "nomaterial")
let noLayer    = UserDefaults.standard.bool(forKey: "nolayer")
let noTitle    = UserDefaults.standard.bool(forKey: "notitle")
let noWrapper  = UserDefaults.standard.bool(forKey: "nowrapper")
let noGutter   = UserDefaults.standard.bool(forKey: "nogutter")
let noHandle   = UserDefaults.standard.bool(forKey: "nohandle")
print("[testbed] variant = \(variant)")
print("[testbed] prodlike toggles: noopaque=\(noOpaque) nomaterial=\(noMaterial) nolayer=\(noLayer) notitle=\(noTitle) nowrapper=\(noWrapper) nogutter=\(noGutter) nohandle=\(noHandle)")

let testItemID = NSToolbarItem.Identifier("EditorTestItem")

/// Plain non-layer-backed view filling itself with a color via drawRect.
final class PlainFillView: NSView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

/// NSRulerView subclass filling its bounds with a color.
final class FillRulerView: NSRulerView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(scrollView: nil, orientation: .verticalRuler)
    }
    required init(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scrollView: NSScrollView!
    var splitItem: NSSplitViewItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "ScrollEdge Test"
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = true
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        // Visible on every Space (incl. over fullscreen apps) for capture
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.level = .floating
        self.window = win

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar

        // ── Editor scroll view ──
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        // MUST stay true (the default): the system uses contentInsets to
        // track the overlapping titlebar AND registers this scroll view
        // with the window's native scroll-edge compositor. Setting false
        // opts out of edge-effect discovery entirely (proven empirically).
        sv.automaticallyAdjustsContentInsets = true
        sv.contentInsets = NSEdgeInsetsZero
        sv.scrollerInsets = NSEdgeInsetsZero

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = true
        tv.backgroundColor = .systemBlue
        tv.textColor = .white
        tv.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        // TEXTURED content: alternate blue/red row backgrounds so ANY
        // scroll-edge blur/fade is unmistakable (blur of solid blue is
        // invisible). Red rows → washed gray under the effect.
        let lines = (1...300).map { i -> String in
            let bg = (i % 2 == 0) ? "BLUE-ROW" : "RED-ROW "
            return "\(bg) LINE \(i)    THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG"
        }
        tv.string = lines.joined(separator: "\n")
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 30
        para.maximumLineHeight = 30
        let full = NSMutableAttributedString(string: tv.string, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ])
        // Row background colors via NSBackgroundColorAttributeName
        let rows = full.string.components(separatedBy: "\n")
        var loc = 0
        for (idx, row) in rows.enumerated() {
            let len = row.utf16.count
            full.addAttribute(.backgroundColor,
                              value: (idx % 2 == 0) ? NSColor.systemBlue : NSColor.systemRed,
                              range: NSRange(location: loc, length: len))
            loc += len + 1 // +1 for newline
        }
        tv.textStorage?.setAttributedString(full)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        sv.documentView = tv
        self.scrollView = sv

        switch variant {
        case "accessory":
            win.contentView = sv
            let acc = NSTitlebarAccessoryViewController()
            acc.layoutAttribute = .bottom
            acc.preferredScrollEdgeEffectStyle = .soft
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "Native Edge Probe")
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 44),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            acc.view = container
            win.addTitlebarAccessoryViewController(acc)
            print("[testbed] accessory: window-level .bottom .soft 44pt plain label")

        case "splititem":
            let split = NSSplitViewController()
            let host = NSViewController()
            host.view = sv
            let item = NSSplitViewItem(viewController: host)
            item.minimumThickness = 100
            split.addSplitViewItem(item)
            win.contentView = split.view
            self.splitItem = item

            let acc = NSSplitViewItemAccessoryViewController()
            acc.preferredScrollEdgeEffectStyle = .soft
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 44),
            ])
            acc.view = container
            item.addTopAlignedAccessoryViewController(acc)
            print("[testbed] accessory: split-item top .soft 44pt plain red view")

        case "prodlike":
            // Replicates AetherCodex production stack trait-for-trait:
            //   non-opaque clear window + behindWindow material behind the
            //   split view + layer-backed clear wrapper around the scroll
            //   view + opaque gutter sibling + drag-handle strip + hidden
            //   title. Each trait can be toggled OFF to bisect.
            if !noOpaque {
                win.isOpaque = false
                win.backgroundColor = .clear
                print("[prodlike] window isOpaque=false backgroundColor=clear")
            }
            if !noTitle {
                win.titleVisibility = .hidden
                print("[prodlike] titleVisibility=.hidden")
            }

            let split = NSSplitViewController()
            if !noLayer {
                split.splitView.wantsLayer = true
                split.splitView.layer?.backgroundColor = NSColor.clear.cgColor
                split.splitView.layer?.isOpaque = false
                print("[prodlike] splitView wantsLayer=true")
            }

            // wrapper view (layer-backed, clear) + opaque gutter sibling +
            // drag-handle strip — the production editor-view anatomy
            let host = NSViewController()
            var item: NSSplitViewItem!
            if noWrapper {
                host.view = sv
                item = NSSplitViewItem(viewController: host)
                item.minimumThickness = 100
                split.addSplitViewItem(item)
                win.contentView = split.view
                self.splitItem = item
                print("[prodlike] nowrapper: scroll view is the item's view directly")
            } else {
                let wrapper = NSView()
                if !noLayer {
                    wrapper.wantsLayer = true
                    wrapper.layer?.backgroundColor = NSColor.clear.cgColor
                    wrapper.layer?.isOpaque = false
                    print("[prodlike] wrapper wantsLayer=true")
                }
                let gutterBelow = UserDefaults.standard.bool(forKey: "gutterbelow")
                let useRuler = UserDefaults.standard.bool(forKey: "ruler")
                let gutterInside = UserDefaults.standard.bool(forKey: "gutterinside")
                let gutterOffset: CGFloat = (noGutter || gutterInside) ? 0 : 52
                if useRuler {
                    // Native NSScrollView ruler — lives INSIDE the scroll view.
                    let ruler = FillRulerView(color: NSColor.gray.withAlphaComponent(0.5))
                    sv.hasVerticalRuler = true
                    sv.verticalRulerView = ruler
                    sv.rulersVisible = true
                    sv.scrollerStyle = .overlay
                    print("[prodlike] NATIVE verticalRulerView (inside scroll view)")
                }
                wrapper.addSubview(sv)
                sv.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    sv.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: gutterOffset),
                    sv.topAnchor.constraint(equalTo: wrapper.topAnchor),
                    sv.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                    sv.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                ])
                if !noGutter {
                    let gutterAlpha = CGFloat(UserDefaults.standard.double(forKey: "gutteralpha"))
                    let gutterPlain = UserDefaults.standard.bool(forKey: "gutterplain")
                    let gutter: NSView
                    if gutterPlain {
                        // non-layer-backed: plain drawRect fill
                        gutter = PlainFillView(color: NSColor.gray.withAlphaComponent(gutterAlpha))
                        print("[prodlike] gutter (plain drawRect, alpha=\(gutterAlpha)) added")
                    } else {
                        gutter = NSView()
                        gutter.wantsLayer = true
                        gutter.layer?.backgroundColor = NSColor.gray.withAlphaComponent(gutterAlpha).cgColor
                        gutter.layer?.isOpaque = (gutterAlpha >= 1.0)
                        print("[prodlike] gutter (layer-backed, alpha=\(gutterAlpha)) added")
                    }
                    if gutterInside {
                        // gutter lives INSIDE the scroll view — sv stays the item content
                        gutter.translatesAutoresizingMaskIntoConstraints = false
                        sv.addSubview(gutter)
                        sv.contentInsets = NSEdgeInsets(top: 0, left: 52, bottom: 0, right: 0)
                        NSLayoutConstraint.activate([
                            gutter.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
                            gutter.topAnchor.constraint(equalTo: sv.topAnchor),
                            gutter.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
                            gutter.widthAnchor.constraint(equalToConstant: 52),
                        ])
                        print("[prodlike] gutter INSIDE scroll view + contentInsets.left=52")
                    } else {
                        wrapper.addSubview(gutter, positioned: gutterBelow ? .below : .above, relativeTo: sv)
                        gutter.translatesAutoresizingMaskIntoConstraints = false
                        NSLayoutConstraint.activate([
                            gutter.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                            gutter.topAnchor.constraint(equalTo: wrapper.topAnchor),
                            gutter.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                            gutter.widthAnchor.constraint(equalToConstant: 52),
                        ])
                        if gutterBelow { print("[prodlike] gutter BELOW scroll view (z-order)") }
                    }
                }
                if noGutter && UserDefaults.standard.bool(forKey: "offset") {
                    // scroll view offset 52pt with NO gutter — isolate offset vs presence
                    sv.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 52).isActive = true
                    print("[prodlike] scroll view offset 52pt (no gutter)")
                }
                if !noHandle {
                    let handle = NSView()
                    handle.wantsLayer = true
                    handle.layer?.backgroundColor = NSColor.clear.cgColor
                    wrapper.addSubview(handle)
                    handle.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        handle.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                        handle.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                        handle.topAnchor.constraint(equalTo: wrapper.topAnchor),
                        handle.heightAnchor.constraint(equalToConstant: 24),
                    ])
                    print("[prodlike] drag-handle strip (clear, 24pt) added")
                }
                host.view = wrapper
                item = NSSplitViewItem(viewController: host)
                item.minimumThickness = 100
                split.addSplitViewItem(item)
                win.contentView = split.view
                self.splitItem = item
            }

            let acc = NSSplitViewItemAccessoryViewController()
            acc.preferredScrollEdgeEffectStyle = .soft
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 44),
            ])
            acc.view = container
            item.addTopAlignedAccessoryViewController(acc)
            print("[prodlike] accessory: split-item top .soft 44pt")

            if !noMaterial {
                let bg = NSVisualEffectView()
                bg.material = .windowBackground
                bg.blendingMode = .behindWindow
                bg.state = .active
                bg.wantsLayer = true
                bg.translatesAutoresizingMaskIntoConstraints = false
                split.view.addSubview(bg, positioned: .below, relativeTo: nil)
                NSLayoutConstraint.activate([
                    bg.topAnchor.constraint(equalTo: split.view.topAnchor),
                    bg.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
                    bg.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
                    bg.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
                ])
                print("[prodlike] behindWindow NSVisualEffectView behind split view")
            }

        default:
            win.contentView = sv
            print("[testbed] accessory: none (plain)")
        }

        // Geometry + scroll after first layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.logGeometry()
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 400))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            print("[testbed] scrolled to y=400")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.logGeometry()
            }
        }

        win.center()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        print("[testbed] window ordered front, isVisible will be logged")
    }

    func logGeometry() {
        guard let win = window else { return }
        win.contentView?.layoutSubtreeIfNeeded()
        print("[geo] window frame: \(win.frame)")
        print("[geo] contentLayoutRect: \(win.contentLayoutRect)")
        print("[geo] contentView frame: \(String(describing: win.contentView?.frame))")
        print("[geo] scrollView frame: \(scrollView.frame)")
        print("[geo] scrollView inWindow: \(scrollView.convert(scrollView.bounds, to: nil))")
        print("[geo] clip bounds: \(scrollView.contentView.bounds)")
        print("[geo] contentSize: \(scrollView.contentSize)")
        print("[geo] documentVisibleRect: \(scrollView.documentVisibleRect)")
        var ancestor: NSView? = scrollView
        while let v = ancestor {
            print("[anc] \(type(of: v)) frame=\(v.frame) bounds=\(v.bounds) wantsLayer=\(v.wantsLayer) masksToBounds=\(String(describing: v.layer?.masksToBounds))")
            ancestor = v.superview
        }
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, testItemID]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, testItemID, .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == testItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Editor"
        item.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Editor")
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()