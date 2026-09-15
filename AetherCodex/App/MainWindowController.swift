import Cocoa
import SwiftUI

// MARK: - Glass Pane Compatibility

/// Factory for creating glass effect panes that work on both macOS 15 and 26+.
/// Returns a view controller containing an appropriately-sized glass effect view.
func makeGlassPaneVC(wrapping content: NSView, cornerRadius: CGFloat = 18) -> NSViewController {
    let vc = NSViewController()
    
    if #available(macOS 26.0, *) {
        vc.view = GlassPane(wrapping: content, cornerRadius: cornerRadius)
    } else {
        // Use hudWindow material for translucent glass effect
        vc.view = VisualEffectPane(wrapping: content, material: .windowBackground, cornerRadius: cornerRadius)
    }
    
    return vc
}

// MARK: - Sidebar Tab

struct SidebarTab {
    let id: String
    let title: String
    let symbolName: String
    let tooltip: String
}

// MARK: - SidebarContainer

/// Hosts the icon-strip tab bar + content area for the sidebar.
/// When collapsed to icon-only mode, shows a top tab bar (sidebarAdaptable).
final class SidebarContainer: NSViewController {

    private let tabs: [SidebarTab]
    private var tabButtons: [NSButton] = []
    private var iconStack: NSStackView!
    private(set) var contentContainer: NSView!
    private var topTabBar: NSSegmentedControl!
    private var isCollapsed = false

    var selectedTabId: String { tabs[selectedIndex].id }
    private var selectedIndex: Int = 0 {
        didSet { updateTabSelection() }
    }

    /// The top tab bar view — host this above the editor when sidebar is collapsed.
    var topTabBarView: NSView { topTabBar }
    
    /// Sidebar glass surface — NSVisualEffectView with .withinWindow blending.
    /// Carries its own material distinct from the shared glassBg.
    var backgroundFill: NSView!
    /// Tint subview inside backgroundFill — carries the sidebar color.
    private var backgroundTintView: NSView!

    var onTabSelected: ((String) -> Void)?
    var onToggleSidebar: (() -> Void)?

    init(tabs: [SidebarTab]) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func setContentView(_ view: NSView, forTabId id: String) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = (id != selectedTabId)
        view.removeFromSuperview()
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        contentContainer.isHidden = collapsed
        topTabBar.isHidden = !collapsed
        iconStack.isHidden = collapsed
        // backgroundFill always visible — provides continuous surface: sidebar → divider → gutter
    }

    /// Top inset for sidebar content — pushes icons & file list below traffic lights.
    /// Background fill still extends full height behind the traffic lights for glass effect.
    // The SwiftUI bar already reserves its header height. Align the icons with
    // the first file row (28 pt below the path label), not another full toolbar.
    private let sidebarIconTopInset: CGFloat = 92
    private let sidebarLeftInset: CGFloat = 0

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.isOpaque = false   // non-opaque so subpixel compositing works
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        // --- Icon strip (vertical, always visible when expanded) ---
        iconStack = NSStackView()
        iconStack.orientation = .vertical
        iconStack.spacing = 4
        iconStack.alignment = .centerX
        iconStack.edgeInsets = NSEdgeInsets(top: 8, left: 2, bottom: 0, right: 2)
        iconStack.translatesAutoresizingMaskIntoConstraints = false

        for (i, tab) in tabs.enumerated() {
            guard let img = NSImage(systemSymbolName: tab.symbolName,
                                     accessibilityDescription: tab.title) else {
                print("[SidebarContainer] SF Symbol not found: \(tab.symbolName)")
                continue
            }
            let btn = NSButton(image: img,
                               target: self, action: #selector(tabButtonClicked(_:)))
            btn.tag = i
            btn.bezelStyle = .smallSquare
            btn.isBordered = false
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.toolTip = tab.tooltip
            NSLayoutConstraint.activate([
                iconStack.widthAnchor.constraint(equalToConstant: 28),
                btn.heightAnchor.constraint(equalToConstant: 24),
            ])
            tabButtons.append(btn)
            iconStack.addArrangedSubview(btn)
        }

        // --- Top tab bar (sidebarAdaptable style — shown when collapsed) ---
        topTabBar = NSSegmentedControl(
            labels: tabs.map { $0.title },
            trackingMode: .selectOne,
            target: self,
            action: #selector(topTabChanged(_:))
        )
        topTabBar.segmentStyle = .separated
        topTabBar.translatesAutoresizingMaskIntoConstraints = false
        topTabBar.isHidden = true
        topTabBar.segmentDistribution = .fit

        // --- Content container ---
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // Background fill — plain tint view. The shared bgCG on the splitView provides
        // the base glass depth. No double glass here; the sidebar-edge fade mask on the
        // editor creates the glass illusion at the boundary instead.
        backgroundFill = NSView()
        backgroundFill.translatesAutoresizingMaskIntoConstraints = false
        backgroundFill.wantsLayer = true
        backgroundFill.layer?.backgroundColor = NSColor.clear.cgColor
        
        // Tint subview — carries sidebarColor above the glass, below content
        backgroundTintView = NSView()
        backgroundTintView.translatesAutoresizingMaskIntoConstraints = false
        backgroundTintView.wantsLayer = true
        backgroundTintView.layer?.backgroundColor = NSColor.clear.cgColor
        backgroundFill.addSubview(backgroundTintView)
        NSLayoutConstraint.activate([
            backgroundTintView.topAnchor.constraint(equalTo: backgroundFill.topAnchor),
            backgroundTintView.leadingAnchor.constraint(equalTo: backgroundFill.leadingAnchor),
            backgroundTintView.trailingAnchor.constraint(equalTo: backgroundFill.trailingAnchor),
            backgroundTintView.bottomAnchor.constraint(equalTo: backgroundFill.bottomAnchor),
        ])

        view.addSubview(backgroundFill, positioned: .below, relativeTo: nil)
        view.addSubview(iconStack)
        view.addSubview(contentContainer)
        
        NSLayoutConstraint.activate([
            // Background fill covers entire sidebar container (full height behind traffic lights)
            backgroundFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundFill.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            iconStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sidebarLeftInset),
            iconStack.topAnchor.constraint(equalTo: view.topAnchor, constant: sidebarIconTopInset),
            iconStack.widthAnchor.constraint(equalToConstant: 36),

            contentContainer.leadingAnchor.constraint(equalTo: iconStack.trailingAnchor, constant: 4),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateTabSelection()
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        selectedIndex = sender.tag
        onTabSelected?(tabs[selectedIndex].id)
    }

    @objc private func topTabChanged(_ sender: NSSegmentedControl) {
        selectedIndex = sender.selectedSegment
        onTabSelected?(tabs[selectedIndex].id)
    }

    private func updateTabSelection() {
        for (i, btn) in tabButtons.enumerated() {
            btn.contentTintColor = (i == selectedIndex) ? accentColor : dimmedColor
        }
        topTabBar.selectedSegment = selectedIndex
    }

    /// Apply theme colors: tab icon tints only. Glass material + tint are set via applySidebarGlass.
    func applyThemeColors(tintColor: NSColor, accent: NSColor, dimmed: NSColor) {
        accentColor = accent
        dimmedColor = dimmed
        // backgroundFill + tint managed exclusively by MainWindowController.applySidebarTint
        updateTabSelection()
    }
    
    /// Apply tint to the sidebar section.
    /// backgroundFill carries the rulerBackground — same as the line number
    /// gutter — forming one continuous surface: sidebar → divider → gutter.
    /// backgroundTintView carries an optional glass-tint overlay (sidebarBackground).
    func applySidebarTint(fill: NSColor, tint: NSColor) {
        backgroundFill?.layer?.backgroundColor = fill.cgColor
        backgroundTintView?.layer?.backgroundColor = tint.cgColor
        // backgroundFill always visible — rulerBackground surface persists regardless of collapse
    }

    /// The sidebar glass material slider is still themable but now just controls tint/transparency
    /// — the actual glass effect comes from the editor's horizontal edge mask, not a separate
    /// glass view. applySidebarTint handles visibility.

    private var accentColor: NSColor = .controlAccentColor
    private var dimmedColor: NSColor = .secondaryLabelColor
}

// MARK: - Seamless Split View

/// NSSplitView subclass that draws transparent dividers — sidebar and line-number
/// ruler form one continuous visual surface without visible seams.
final class SeamlessSplitView: NSSplitView {
    var seamlessDividerColor: NSColor = .clear
    override var dividerColor: NSColor { seamlessDividerColor }
}

// MARK: - Main Window Controller (Liquid Glass)

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    var fileBrowser: FileBrowserViewController!
    var editorViewController: EditorViewController!
    private var pythiaModel = PythiaChatModel()
    private var splitVC: NSSplitViewController!
    private var editorItem: NSSplitViewItem!
    private var editorHeaderView: EditorHeaderView!
    private var sidebarContainer: SidebarContainer!
    private var topTabBarHost: NSView!
    private var overlayPanel: OverlayFileBrowserPanel?
    private var sidebarFloatingPanel: FloatingOverlayPanel?
    private var pythiaFloatingPanel: FloatingOverlayPanel?
    private var themeObserver: Any?
    private var statusBar: NSVisualEffectView!
    private var statusLabel: NSTextField!
    private var chromeState: EditorChromeState!
    private var documentModel: EditorDocumentModel!
    
    private var lastSidebarExpanded = false
    private var isAnimatingSidebar = false
    private var isAnimatingPythia = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled – ÆtherCodex"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 800, height: 600)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Keep the full-size content canvas visible behind floating toolbar
        // items. A solid titlebar creates an opaque strip, not Liquid Glass.
        window.titlebarAppearsTransparent = true
        // The custom sidebar resize strips must receive their drags. The real
        // titlebar remains draggable through AppKit without turning every clear
        // background region into a window-drag surface.
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
        setupLiquidGlass()
    }

    // MARK: - Liquid Glass Architecture
    private func setupLiquidGlass() {
        guard let window = window else {
            print("[MainWindowController] FATAL: window is nil — setup aborted")
            return
        }

        // ── ScopeSettings: load ~/.aether-properties on launch ──
        ScopeSettings.shared.loadGlobal()

        // Editor background is a SwiftUI Material (see EditorContainerView), driven
        // by the theme's glassBlurStrength + glassTint — no AppKit glass view here.
        // ── Sidebar (left pane) ──
        sidebarContainer = SidebarContainer(tabs: [
            SidebarTab(id: "files",  title: "Files",  symbolName: "folder",                 tooltip: "File Browser"),
            SidebarTab(id: "search", title: "Search", symbolName: "magnifyingglass",        tooltip: "Search"),
            SidebarTab(id: "git",    title: "Git",    symbolName: "arrow.triangle.branch",  tooltip: "Git"),
        ])
        sidebarContainer.onTabSelected = { [weak self] id in
            guard let self else { return }
            switch id {
            case "files":  self.fileBrowser?.view.isHidden = false
            case "search": self.fileBrowser?.view.isHidden = true
            case "git":    self.fileBrowser?.view.isHidden = true
            default: break
            }
        }
 
        // Force-load sidebarContainer.view so loadView() populates contentContainer
        _ = sidebarContainer.view
 
        fileBrowser = FileBrowserViewController()
        fileBrowser.setTransparentBackground()
        fileBrowser.onFileOpen = { [weak self] url in
            self?.editorViewController?.openFile(url)
        }
        fileBrowser.onFolderOpen = { _ in
            // just navigated; no action
        }
        sidebarContainer.setContentView(fileBrowser.view, forTabId: "files")

        // ── Editor (center pane) ──
        editorViewController = EditorViewController()
        _ = editorViewController.view  // force-load so viewDidLoad fires
        editorViewController.onTitleChange = { [weak self] title in
            self?.window?.title = title
            self?.chromeState?.title = title
        }

        // ── Pythia (right pane) — pure SwiftUI PythiaPanel, no WebView ──

        // ── SwiftUI safeAreaBar host (replaces NSSplitViewController) ──
        // safeAreaBar(edge: .top/.leading/.trailing) + .scrollEdgeEffectStyle(.soft)
        // provide native scroll-edge blur on all three edges — something AppKit's
        // NSSplitViewItemAccessoryViewController cannot do (top/bottom only).

        // ── Top tab bar host (collapsed sidebar tabs) ──
        topTabBarHost = NSView()
        topTabBarHost.translatesAutoresizingMaskIntoConstraints = false
        topTabBarHost.isHidden = true

        // ── Status bar ──
        statusBar = NSVisualEffectView(frame: .zero)
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow
        statusBar.state = .active
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusBar.addSubview(statusLabel)

        // ── Assemble SwiftUI host as window content ──
        chromeState = EditorChromeState()
        chromeState.sidebarWidth = CGFloat(SessionState.shared.sidebarWidth ?? 180)
        chromeState.pythiaWidth = CGFloat(SessionState.shared.pythiaWidth ?? 280)
        
        // Wire up traffic lights repositioning when sidebar visibility changes
        chromeState.onSidebarVisibilityChange = { [weak self] visible in
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self?.positionTrafficLights(sidebarVisible: visible, animated: true)
                }
            }
        }

        // Fold away the AppKit overlays (status bar, collapsed tab bar) when the
        // window flips into oracle-only — Pythia stands alone on the reverse face.
        chromeState.onOracleOnlyChange = { [weak self] oracleOnly in
            guard let self else { return }
            self.statusBar.isHidden = oracleOnly
            // The tab bar is only normally visible when the sidebar is collapsed;
            // preserve that condition when the card flips back.
            self.topTabBarHost.isHidden = oracleOnly || self.chromeState.sidebarVisible
        }

        documentModel = EditorDocumentModel()
        editorViewController.onDocumentChange = { [weak self] attributedString in
            self?.documentModel.attributedString = attributedString
            self?.documentModel.revision += 1
        }

        // The AppKit editor's view is never laid out in the SwiftUI hierarchy (the
        // TextKit 2 surface replaces it), so its deferred `newDocument()` — which
        // fires from `layout()` when the view first gets a non-zero frame — never
        // runs. Seed the initial document explicitly so the surface isn't empty
        // (an empty document also collapses the ScrollView to a 1×1 content and
        // shrinks the whole window).
        if editorViewController.highlightedDocument().length == 0 {
            editorViewController.newDocument()
        }

        let containerView = OracleFlipRoot(
            editor: editorViewController,
            sidebar: sidebarContainer.view,
            pythiaModel: pythiaModel,
            chrome: chromeState,
            document: documentModel
        )
        // Host the SwiftUI content in a plain `NSHostingView` (not
        // `NSHostingController`) with autoresizing enabled, so the window frame
        // stays authoritative. `NSHostingController` sizes the window to the
        // SwiftUI content's ideal size, collapsing it to the document height
        // (or just the chrome) on every launch.
        let hostingView = NSHostingView(rootView: containerView)
        // Keep the window frame authoritative: drop `.intrinsicContentSize` and
        // `.preferredContentSize` (which size the window to the SwiftUI ideal
        // size — the document height), keeping only the min/max bounds.
        hostingView.sizingOptions = [.minSize, .maxSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let hostController = NSViewController()
        hostController.view = hostingView
        window.contentViewController = hostController

        let liveView = hostingView

        // Status bar + top tab bar float above the editor (AppKit overlays).
        liveView.addSubview(topTabBarHost)
        liveView.addSubview(statusBar)

        NSLayoutConstraint.activate([
            topTabBarHost.leadingAnchor.constraint(equalTo: liveView.leadingAnchor),
            topTabBarHost.trailingAnchor.constraint(equalTo: liveView.trailingAnchor),
            topTabBarHost.topAnchor.constraint(equalTo: liveView.topAnchor),
            topTabBarHost.heightAnchor.constraint(equalToConstant: 36),

            statusBar.leadingAnchor.constraint(equalTo: liveView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: liveView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: liveView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        // Ensure the text view gets focus when window becomes key
        window.initialFirstResponder = editorViewController.textView

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyGlassTints()
            self?.syncOverlayMode()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.saveSessionState()
            self?.positionTrafficLights()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.saveSessionState()
        }
        NotificationCenter.default.addObserver(
            forName: .openFileInEditor, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            self?.editorViewController?.openFile(url)
        }
        // Restore saved session state
        if let lastFolder = SessionState.shared.lastProjectFolder {
            fileBrowser.openFolder(URL(fileURLWithPath: lastFolder))
        }

        applyGlassTints()
        applyWindowRounding()

    }

    // MARK: - Window rounding + nested traffic lights

    /// Rounds the window content to a Tahoe-style radius and nests the traffic
    /// lights inside the corner. The glass is a SwiftUI `Material` (not an AppKit
    /// `NSVisualEffectView`), so `masksToBounds` on the content layer clips the
    /// rounded silhouette without killing the material's backdrop blur.
    private func applyWindowRounding() {
        guard let window, let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 24
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.backgroundColor = .clear

        // AppKit performs one more titlebar layout pass after installing the
        // content controller. Position against the actual content bounds after
        // that pass so the controls remain nested in the inset sheet.
        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLights()
        }
    }

    /// Places traffic-light centers in content-view coordinates, making the
    /// result independent of AppKit's private titlebar coordinate orientation.
    /// When sidebar is visible, buttons move into the sidebar area.
    private func positionTrafficLights(sidebarVisible: Bool? = nil, animated: Bool = false) {
        guard let window, let contentView = window.contentView else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let centerFromTop: CGFloat = 24
        
        // When sidebar is visible, offset buttons to sit inside the sidebar
        // The sidebar has 12px leading padding, so buttons move right by that amount
        let visible = sidebarVisible ?? chromeState?.sidebarVisible ?? true
        let xOffset: CGFloat = visible ? SidebarSheetGeometry.leading : 0

        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type),
                  let buttonParent = button.superview else { continue }

            let centerInContent = NSPoint(
                x: 20 + CGFloat(index) * 20 + xOffset,
                y: contentView.isFlipped
                    ? centerFromTop
                    : contentView.bounds.maxY - centerFromTop
            )
            let centerInParent = contentView.convert(centerInContent, to: buttonParent)
            let origin = NSPoint(
                x: centerInParent.x - button.frame.width / 2,
                y: centerInParent.y - button.frame.height / 2
            )
            if animated {
                button.animator().setFrameOrigin(origin)
            } else {
                button.setFrameOrigin(origin)
            }
        }
    }

    // MARK: - Floating Overlay Panels

    /// Creates the sidebar and Pythia floating overlay panels as siblings
    /// of splitVC.splitView inside the given content view.
    private func setupFloatingOverlayPanels(in contentView: NSView) {
        // ── Sidebar floating panel (leading edge) ──
        let sidebarPanel = FloatingOverlayPanel(
            contentView: sidebarContainer.view
        )
        sidebarPanel.onWidthChanged = { [weak self] width in
            self?.editorViewController?.sidebarOverlayWidth = width
            self?.saveSessionState()
        }
        sidebarFloatingPanel = sidebarPanel

        // ── Pythia floating panel (trailing edge) ──
        let pythiaPanel = FloatingOverlayPanel(
            contentView: NSHostingView(rootView: PythiaPanel(model: pythiaModel))
        )
        pythiaPanel.onWidthChanged = { [weak self] width in
            self?.editorViewController?.pythiaOverlayWidth = width
            self?.saveSessionState()
        }
        pythiaFloatingPanel = pythiaPanel

        // Preload panels into contentView (hidden by default)
        sidebarPanel.prepare(in: contentView, atEdge: .leading)
        pythiaPanel.prepare(in: contentView, atEdge: .trailing)
    }

    private func sidebarWidth() -> CGFloat {
        chromeState?.sidebarWidth ?? CGFloat(SessionState.shared.sidebarWidth ?? 180)
    }

    // MARK: - Top Tab Bar (sidebarAdaptable)

    private func updateTopTabBar(collapsed: Bool) {
        guard let host = topTabBarHost, let container = sidebarContainer else { return }
        host.isHidden = !collapsed
        if collapsed {
            let tabBar = container.topTabBarView
            tabBar.removeFromSuperview()
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 48),
                tabBar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
                tabBar.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            ])
        }
    }

    // Helper to get the glass view from a split view item's view controller
    private func glassView(from item: NSSplitViewItem?) -> NSView? {
        return item?.viewController.view
    }

    // MARK: - Overlay File Browser

    func syncOverlayMode() {
        let overlay = ThemeSettings.shared.fileBrowserOverlay
        if overlay {
            showOverlayIfNeeded()
        } else {
            dismissOverlayIfNeeded()
        }
    }

    private func showOverlayIfNeeded() {
        guard ThemeSettings.shared.fileBrowserOverlay, overlayPanel == nil,
              let window = window, let editor = editorViewController else { return }

        let overlayFB = FileBrowserViewController()
        overlayFB.onFileOpen = { [weak editor] url in
            editor?.openFile(url)
        }
        _ = overlayFB.view
        overlayFB.rootItem = fileBrowser?.rootItem

        let panel = OverlayFileBrowserPanel(fileBrowser: overlayFB)
        panel.show(editorView: editor.view, parentWindow: window)
        overlayPanel = panel

        panel.onDismiss = { [weak self] in
            self?.overlayPanel = nil
            ThemeSettings.shared.fileBrowserOverlay = false
        }
    }

    private func dismissOverlayIfNeeded() {
        overlayPanel?.dismiss()
        overlayPanel = nil
    }

    // MARK: - Glass

    private func applyGlassTints() {
        let theme = ThemeRegistry.shared.current
        let settings = ThemeSettings.shared
        
        // Editor background is a SwiftUI Material (see EditorContainerView).
        // Push the active theme into observable chrome so the SwiftUI material
        // + tint re-render on theme change.
        chromeState?.theme = theme
        
        // ── Window appearance ──
        window?.appearance = NSAppearance(named: theme.kind == .dark ? .darkAqua : .aqua)
        window?.backgroundColor = .clear
        
        let bgOpacity = settings.resolvedEditorBackgroundOpacity(for: theme)
        _ = theme.editorBackground.withAlphaComponent(bgOpacity)
        let rulerBg = theme.rulerBackground

        // ── Sidebar section: splitView provides the unified surface behind all panes.
        let tintOverlay: NSColor
        let tabTint: NSColor
        if let sideBg = theme.sidebarBackground {
            let sideOpacity = settings.resolvedSidebarBackgroundOpacity(for: theme)
            tintOverlay = sideBg.withAlphaComponent(sideOpacity)
            tabTint = tintOverlay
        } else {
            tintOverlay = .clear
            tabTint = rulerBg
        }

        // SwiftUI provides the opaque sidebar surface via `.background`; clear the
        // AppKit fill so the two layers never disagree (no double tint).
        sidebarContainer?.applySidebarTint(fill: .clear, tint: .clear)
        // SwiftUI owns the inspector's material; no AppKit backing remains.

        // Split view = clear — Liquid Glass shows through in titlebar zone & dividers.
        (splitVC?.splitView as? SeamlessSplitView)?.seamlessDividerColor = .clear
        
        // Tab icon tints
        sidebarContainer?.applyThemeColors(
            tintColor: tabTint,
            accent: theme.glassTintColor,
            dimmed: theme.editorForeground.withAlphaComponent(0.45)
        )
        fileBrowser?.applyForegroundColor(theme.sidebarForeground, accent: theme.sidebarAccent)
        fileBrowser?.setTransparentBackground()

    }


    /// Human-readable name for the material at a given blur strength.
    func materialNameForBlurStrength(_ strength: CGFloat) -> String {
        return glassMaterialName(for: strength)
    }

    /// Map a string material name to NSVisualEffectView.Material.
    func materialForName(_ name: String) -> NSVisualEffectView.Material {
        switch name.lowercased() {
        case "fullscreenui", "fullscreen":  return .fullScreenUI
        case "tooltip":                     return .toolTip
        case "menu":                        return .menu
        case "sidebar":                     return .sidebar
        case "sheet":                       return .sheet
        case "windowbackground", "window":   return .windowBackground
        case "underwindowbackground", "underwindow", "under": return .underWindowBackground
        case "hudwindow", "hud":            return .hudWindow
        case "header":                      return .headerView
        case "contentbackground", "content": return .contentBackground
        default:                            return .sidebar
        }
    }


    deinit {
        if let o = themeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Session Persistence

    func restoreSidebarWidth(_ width: CGFloat) {
        chromeState?.sidebarWidth = width
    }

    func restorePythiaWidth(_ width: CGFloat) {
        chromeState?.pythiaWidth = width
    }

    /// Gather current state into SessionState for persistence.
    func saveSessionState() {
        let s = SessionState.shared

        // Window frame
        if let frame = window?.frame {
            s.windowFrame = SessionData.WindowFrame(
                x: frame.origin.x, y: frame.origin.y,
                width: frame.width, height: frame.height
            )
        }

        // Project folder
        s.lastProjectFolder = fileBrowser?.rootItem?.url.path

        // Open file
        s.lastOpenFile = editorViewController?.currentFile?.path

        // safeAreaBar widths (single-pane architecture)
        if chromeState?.sidebarVisible == true {
            s.sidebarWidth = Double(chromeState?.sidebarWidth ?? 180)
        }
        if chromeState?.pythiaVisible == true {
            s.pythiaWidth = Double(chromeState?.pythiaWidth ?? 280)
        }

        // Overlay mode
        s.fileBrowserOverlay = ThemeSettings.shared.fileBrowserOverlay

        // Sidebar tab
        s.selectedSidebarTab = sidebarContainer?.selectedTabId

        // Theme
        s.activeThemeName = ThemeRegistry.shared.current.name
    }

    // MARK: - Menu Actions

    // MARK: - Window Close
    
    func windowWillClose(_ notification: Notification) {
        saveSessionState()
        (NSApp.delegate as? AppDelegate)?.windowControllerWillClose(self)
    }

    /// Restore text view focus when the window becomes key — prevents
    /// the "click to type" friction after dismissing search or switching apps.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !(editorViewController?.incrementalSearchBar.isVisible ?? false) else { return }
        window?.makeFirstResponder(editorViewController?.textView)
    }
    
    // MARK: - Session Export/Restore (multi-window)
    
    func exportWindowState() -> WindowState {
        var s = WindowState()
        if let f = window?.frame {
            s.frame = WindowState.FrameDesc(x: f.origin.x, y: f.origin.y,
                                             width: f.width, height: f.height)
        }
        s.lastOpenFile = editorViewController?.currentFile?.path
        s.lastProjectFolder = fileBrowser?.rootItem?.url.path
        if chromeState?.sidebarVisible == true {
            s.sidebarWidth = Double(chromeState?.sidebarWidth ?? 180)
        }
        if chromeState?.pythiaVisible == true {
            s.pythiaWidth = Double(chromeState?.pythiaWidth ?? 280)
        }
        return s
    }
    
    func restoreWindowState(_ state: WindowState) {
        guard let window = window else { return }
        if let f = state.frame {
            window.setFrame(NSRect(x: f.x, y: f.y, width: f.width, height: f.height), display: true)
        }
        if let w = state.sidebarWidth { restoreSidebarWidth(CGFloat(w)) }
        if let w = state.pythiaWidth { restorePythiaWidth(CGFloat(w)) }
        if let path = state.lastProjectFolder {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                fileBrowser?.openFolder(url)
            }
        }
        if let path = state.lastOpenFile {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                editorViewController?.openFile(url)
            }
        }
    }

    @objc func openFolder(_ sender: Any?) {
        guard let fb = fileBrowser else {
            print("[MainWindowController] fileBrowser nil — cannot open folder")
            return
        }
        fb.browseForFolder()
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let editor = editorViewController else {
            print("[MainWindowController] editorViewController nil — cannot save")
            return
        }
        editor.saveDocument()
    }

    // MARK: - Pane Toggles

    /// Toggle sidebar (left pane). Slides the floating overlay panel
    /// in from the leading edge.
    @objc func toggleFileBrowser(_ sender: Any?) {
        toggleFileBrowserAnimated(sender)
    }
    
    @objc private func toggleFileBrowserAnimated(_ sender: Any?) {
        guard let chrome = chromeState else { return }
        // Guard against overlapping animations — rapid ⌘1 spam could
        // stack multiple show/dismiss groups and cause visual glitches.
        guard !isAnimatingSidebar else { return }
        isAnimatingSidebar = true

        let willExpand = !chrome.sidebarVisible
        lastSidebarExpanded = willExpand

        withAnimation(.easeInOut(duration: 0.2)) {
            chrome.sidebarVisible = willExpand
        }
        sidebarContainer.setCollapsed(!willExpand)

        // Reset after animation completes (0.2s show / 0.18s dismiss).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isAnimatingSidebar = false
        }
        saveSessionState()
    }
    
    /// Toggle Pythia (right pane). Slides the floating overlay panel
    /// in from the trailing edge.
    @objc func togglePythia(_ sender: Any?) {
        guard let chrome = chromeState else { return }
        // Guard against overlapping animations — mirror of sidebar guard.
        guard !isAnimatingPythia else { return }
        isAnimatingPythia = true

        let willExpand = !chrome.pythiaVisible
        withAnimation(.easeInOut(duration: 0.2)) {
            chrome.pythiaVisible = willExpand
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isAnimatingPythia = false
        }
        saveSessionState()
    }

    /// Toggle Oracle-only mode. Instead of sliding a panel wider, the whole
    /// window turns over like a card — Pythia alone on the reverse face.
    @objc func toggleOracleOnly(_ sender: Any?) {
        guard let chrome = chromeState else { return }
        // Folding the side panel away keeps only the reverse-face Pythia alive,
        // so the shared chat model is never observed twice at rest.
        if !chrome.oracleOnly {
            chrome.pythiaVisible = false
        }
        withAnimation(.easeInOut(duration: 0.62)) {
            chrome.oracleOnly.toggle()
        }
    }
}

// MARK: - NSToolbarDelegate

extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("SidebarToggle")
    static let documentTitle = NSToolbarItem.Identifier("DocumentTitle")
}

extension MainWindowController {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .flexibleSpace, .documentTitle, .flexibleSpace]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .flexibleSpace, .space, .documentTitle]
    }
    
    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sidebar.left",
                                 accessibilityDescription: "Toggle Sidebar")
            item.label = "Sidebar"
            item.paletteLabel = "Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.target = self
            item.action = #selector(toggleFileBrowserAnimated(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        case .documentTitle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Document Title"
            item.paletteLabel = "Document Title"
            let titleField = NSTextField(labelWithString: window?.title ?? "Untitled")
            titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            titleField.textColor = .labelColor
            titleField.lineBreakMode = .byTruncatingTail
            titleField.alignment = .center
            titleField.isEditable = false
            titleField.isSelectable = false
            titleField.drawsBackground = false
            titleField.isBezeled = false
            titleField.tag = 42  // marker for title updates
            item.view = titleField
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }
    
    @objc func toggleWordWrap(_ sender: Any?) {
        // Per-window override — doesn't touch global/user defaults state.
        // nil → false, false → true, true → nil
        guard let evc = editorViewController else { return }
        if evc.wordWrapOverride == nil {
            evc.wordWrapOverride = false
        } else if evc.wordWrapOverride == false {
            evc.wordWrapOverride = true
        } else {
            evc.wordWrapOverride = nil
        }
        evc.applyWordWrap()
    }
    
    @objc func toggleHighlightCurrentLine(_ sender: Any?) {
        ThemeSettings.shared.highlightCurrentLine.toggle()
        editorViewController?.applyThemeChrome()
    }
    
    @objc func goToFile(_ sender: Any?) {
        guard let root = fileBrowser?.rootItem?.url else { return }
        GoToFilePanel.show(projectRoot: root) { [weak self] url in
            self?.editorViewController?.openFile(url)
            self?.saveSessionState()
        }
    }
    
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = (editorViewController?.effectiveWordWrap ?? false) ? .on : .off
        }
        if menuItem.action == #selector(toggleHighlightCurrentLine(_:)) {
            menuItem.state = ThemeSettings.shared.highlightCurrentLine ? .on : .off
        }
        return true
    }
}
// MARK: - Overlay File Browser Panel

/// Floating glass overlay panel — sits atop the editor as a subview of the main window
/// (NOT a separate NSPanel child window) so .withinWindow blending can blur the
/// actual editor content + main glass surface beneath it. Child NSPanel with
/// .behindWindow competes for the single desktop punch-through slot and renders muddy.
private final class OverlayFileBrowserPanel: NSObject {

    let glassView: NSVisualEffectView
    let fileBrowser: FileBrowserViewController
    private var parentView: NSView?
    private weak var parentWindow: NSWindow?
    private var leadingConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?

    var onDismiss: (() -> Void)?

    init(fileBrowser: FileBrowserViewController) {
        self.fileBrowser = fileBrowser

        // .withinWindow blends with whatever content is beneath in the view hierarchy —
        // the editor text + the main window's glassBg. This is the only blending mode
        // that works reliably for an overlay within the same window.
        // .fullScreenUI is the most translucent material — maximum glass, minimal obstruction.
        glassView = NSVisualEffectView()
        glassView.material = .fullScreenUI //.clear //.fullScreenUI
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 14
        glassView.layer?.masksToBounds = true
        glassView.layer?.borderWidth = 0.33
        glassView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        glassView.translatesAutoresizingMaskIntoConstraints = false

        super.init()
    }

    func show(editorView: NSView, parentWindow: NSWindow) {
        self.parentWindow = parentWindow
        self.parentView = editorView.superview  // the editor's container

        guard let host = parentView else { return }

        // Remove any previous instance
        glassView.removeFromSuperview()

        // Embed file browser inside the glass
        fileBrowser.view.translatesAutoresizingMaskIntoConstraints = false
        fileBrowser.setTransparentBackground()
        glassView.addSubview(fileBrowser.view)
        NSLayoutConstraint.activate([
            fileBrowser.view.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            fileBrowser.view.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            fileBrowser.view.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 36),
            fileBrowser.view.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        // --- Glass header with buttons ---
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        glassView.addSubview(header)

        let title = NSTextField(labelWithString: "Files")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let closeBtn = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill",
                           accessibilityDescription: "Close")!,
            target: self, action: #selector(headerCloseClicked))
        closeBtn.bezelStyle = .smallSquare
        closeBtn.isBordered = false
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(closeBtn)

        let pinBtn = NSButton(
            image: NSImage(systemSymbolName: "pin",
                           accessibilityDescription: "Pin")!,
            target: self, action: #selector(headerPinClicked))
        pinBtn.bezelStyle = .smallSquare
        pinBtn.isBordered = false
        pinBtn.contentTintColor = .secondaryLabelColor
        pinBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(pinBtn)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 28),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            pinBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -2),
            pinBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pinBtn.widthAnchor.constraint(equalToConstant: 22),
            pinBtn.heightAnchor.constraint(equalToConstant: 22),

            closeBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -2),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 22),
            closeBtn.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Add glass view to the editor's parent (split view content area)
        host.addSubview(glassView)

        // Position: anchored to the host (editor's container), inset 8px from edges
        leadingConstraint = glassView.leadingAnchor.constraint(
            equalTo: host.leadingAnchor, constant: 8)
        widthConstraint = glassView.widthAnchor.constraint(equalToConstant: 260)
        topConstraint = glassView.topAnchor.constraint(
            equalTo: host.topAnchor, constant: 8)
        bottomConstraint = glassView.bottomAnchor.constraint(
            equalTo: host.bottomAnchor, constant: -8)

        NSLayoutConstraint.activate([
            leadingConstraint!, widthConstraint!, topConstraint!, bottomConstraint!,
        ])

        // Fade in
        glassView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.glassView.animator().alphaValue = 1.0
        }

        // Force layout so outline view gets its frame, then reload
        host.layoutSubtreeIfNeeded()
        fileBrowser.reloadOutline()
    }

    @objc private func headerCloseClicked() {
        dismiss()
    }

    @objc private func headerPinClicked(_ sender: NSButton) {
        // Toggle pin state — cosmetic for now
        let pinned = sender.contentTintColor == .controlAccentColor
        sender.contentTintColor = pinned ? .secondaryLabelColor : .controlAccentColor
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.glassView.animator().alphaValue = 0
        }, completionHandler: {
            self.glassView.removeFromSuperview()
            self.parentView = nil
            self.parentWindow = nil
            self.onDismiss?()
        })
    }
}

// MARK: - Floating Overlay Panel

/// Floating glass overlay panel for sidebar or Pythia content in the
/// single-pane architecture. Sits as a sibling of splitVC.splitView
/// inside contentView — not a split-view item.
///
/// The NSVisualEffectView (.fullScreenUI, .withinWindow) provides native
/// glass blur on content scrolling behind the panel. A thin drag-resize
/// handle at the inner edge allows width adjustment.
private final class FloatingOverlayPanel: NSObject {

    let glassView: NSVisualEffectView
    let contentView: NSView
    let resizeHandle: ResizeHandleView

    private(set) var isVisible = false
    var width: CGFloat = 260 {
        didSet { widthConstraint?.constant = width }
    }
    var onWidthChanged: ((CGFloat) -> Void)?

    /// The host view this panel was prepared in.
    private(set) weak var parentView: NSView?

    private var widthConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?

    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 500

    // MARK: - Init

    init(contentView: NSView) {
        self.contentView = contentView

        glassView = NSVisualEffectView()
        glassView.material = .fullScreenUI
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.translatesAutoresizingMaskIntoConstraints = false

        resizeHandle = ResizeHandleView()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.addSubview(contentView)
        glassView.addSubview(resizeHandle)

        // Content fills the glass, leaving room for the resize handle at inner edge
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        // Resize handle: 5pt strip at the inner boundary
        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: glassView.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 5),
        ])

        resizeHandle.onDrag = { [weak self] delta in
            self?.applyResizeDelta(delta)
        }
    }

    // MARK: - Prepare (add to host, hidden)

    /// Adds the glass view to the host and sets up edge-appropriate constraints.
    /// The panel starts hidden (alpha=0, isVisible=false).
    func prepare(in host: NSView, atEdge edge: NSLayoutConstraint.Attribute) {
        parentView = host
        glassView.removeFromSuperview()
        host.addSubview(glassView)

        widthConstraint = glassView.widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.priority = .dragThatCannotResizeWindow
        widthConstraint?.isActive = true

        let topC = glassView.topAnchor.constraint(equalTo: host.topAnchor)
        let bottomC = glassView.bottomAnchor.constraint(equalTo: host.bottomAnchor)

        switch edge {
        case .leading:
            leadingConstraint = glassView.leadingAnchor.constraint(equalTo: host.leadingAnchor)
            leadingConstraint?.isActive = true

            // Content hugs the left, resize handle at right (inner) edge
            contentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor).isActive = true
            contentView.trailingAnchor.constraint(equalTo: resizeHandle.leadingAnchor).isActive = true
            resizeHandle.trailingAnchor.constraint(equalTo: glassView.trailingAnchor).isActive = true

        case .trailing:
            trailingConstraint = glassView.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            trailingConstraint?.isActive = true

            // Resize handle at left (inner) edge, content fills the rest
            resizeHandle.leadingAnchor.constraint(equalTo: glassView.leadingAnchor).isActive = true
            contentView.leadingAnchor.constraint(equalTo: resizeHandle.trailingAnchor).isActive = true
            contentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor).isActive = true

        default:
            break
        }

        NSLayoutConstraint.activate([topC, bottomC])
        glassView.alphaValue = 0
        glassView.isHidden = true
    }

    // MARK: - Resize

    private func applyResizeDelta(_ delta: CGFloat) {
        let newWidth = min(max(width + delta, minWidth), maxWidth)
        guard newWidth != width else { return }
        width = newWidth
        onWidthChanged?(newWidth)
    }

    // MARK: - Show / Dismiss

    func show(width: CGFloat) {
        guard let host = parentView else {
            return
        }
        self.width = min(max(width, minWidth), maxWidth)
        glassView.isHidden = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.glassView.animator().alphaValue = 1.0
            host.layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.isVisible = true
            self.onWidthChanged?(width)
        })
    }

    func dismiss() {
        isVisible = false
        onWidthChanged?(0)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.glassView.animator().alphaValue = 0
        }, completionHandler: {
            self.glassView.isHidden = true
        })
    }
}

// MARK: - Resize Handle View

/// Thin vertical strip that shows a resize cursor and tracks horizontal
/// drag to resize the parent floating panel.
private final class ResizeHandleView: NSView {

    var onDrag: ((CGFloat) -> Void)?

    private var dragStart: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow.x
        let delta = current - dragStart
        dragStart = current
        onDrag?(delta)
    }
}

// MARK: - Shared Glass Utilities

/// Map blur strength to material.
func glassMaterial(for strength: CGFloat) -> NSVisualEffectView.Material {
    switch strength {
    case 0.0..<0.1: return .hudWindow
    case 0.1..<0.2: return .fullScreenUI
    case 0.2..<0.3: return .popover
    case 0.3..<0.4: return .menu
    case 0.4..<0.5: return .toolTip
    case 0.5..<0.6: return .underWindowBackground
    case 0.6..<0.7: return .sidebar
    case 0.7..<0.8: return .sheet
    case 0.8..<0.9: return .windowBackground
    case 0.9..<1.0: return .contentBackground
    default:        return .contentBackground
    }
}

/// Human-readable name for the SwiftUI material at a given blur strength.
/// Mirrors the thresholds in `SyntaxTheme.editorMaterial`.
func glassMaterialName(for strength: CGFloat) -> String {
    switch strength {
    case ..<0.2:  return "Ultra Thin"
    case ..<0.4:  return "Thin"
    case ..<0.6:  return "Regular"
    case ..<0.8:  return "Thick"
    default:      return "Ultra Thick"
    }
}


// MARK: - NSView → NSViewController adapter

/// Thin wrapper so a GlassPane's view can be used as an NSSplitViewItem.viewController.
private extension NSView {
    var viewController: NSViewController {
        let vc = NSViewController()
        vc.view = self
        return vc
    }
}