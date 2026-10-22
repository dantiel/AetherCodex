import Cocoa
import SwiftUI
// MARK: - Sidebar Tab

struct SidebarTab {
    let id: String
    let title: String
    let symbolName: String
    let tooltip: String
}

// MARK: - SidebarContainer

/// Hosts the sidebar's content panes. The tab switcher is a floating glass
/// capsule docked to the bottom of the sheet; content fills the full width
/// above it (no vertical rail).
final class SidebarContainer: NSViewController {

    private let tabs: [SidebarTab]
    private(set) var contentContainer: NSView!
    private var isCollapsed = false

    /// The tab switcher no longer lives here — the docked sidebar shows it in
    /// a SwiftUI bottom `safeAreaBar` (SafeAreaBarHost.swift, `SidebarTabBar`).
    /// This container only hosts the panes and their show/hide switching.
    var selectedTabId: String { tabs[selectedIndex].id }
    private var selectedIndex: Int = 0

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

    /// Programmatic tab selection — mirrors the old AppKit pill buttons.
    /// The SwiftUI `SidebarTabBar` drives this from the bottom safe-area bar.
    func selectTab(id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), i != selectedIndex else { return }
        selectedIndex = i
        onTabSelected?(id)
    }

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
        // backgroundFill always visible — provides continuous surface: sidebar → divider → gutter
    }

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
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            // Background fill covers entire sidebar container (full height behind traffic lights)
            backgroundFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundFill.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Content fills the sheet down to the window edge — the SwiftUI
            // bottom safe-area bar (SidebarTabBar) overlays its lower band
            // with the native scroll-edge effect.
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Theme colors live in the SwiftUI `SidebarTabBar` now; the container
    /// keeps the values for callers that still apply them.
    func applyThemeColors(tintColor: NSColor, accent: NSColor, dimmed: NSColor) {
        accentColor = accent
        dimmedColor = dimmed
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

// MARK: - Main Window Controller (Liquid Glass)

final class MainWindowController: NSWindowController, NSWindowDelegate, ObservableObject {

    /// Window title mirrored into the SwiftUI scene, which owns the window.
    @Published var windowTitle: String = "Untitled – ÆtherCodex"

    /// The SwiftUI root. SwiftUI's `Window` scene renders this directly; SwiftUI
    /// owns the window's creation, size, and lifecycle.
    private(set) var rootView = AnyView(EmptyView())

    var fileBrowser: FileBrowserViewController!
    private(set) var tabsModel: TabsModel!

    /// Active tab's controller — kept as a computed accessor so the many existing
    /// call sites (`openFile`, search, theme, first responder) keep working.
    var editorViewController: EditorViewController? { tabsModel?.activeEditor }
    var documentModel: EditorDocumentModel? { tabsModel?.activeDocument }
    private var pythiaModel = PythiaChatModel()
    private var sidebarContainer: SidebarContainer!
    private var favouritesVC: FavouritesHostViewController!
    private var gitVC: NSHostingController<GitSidebarView>?
    private var searchVC: NSHostingController<SidebarSearchView>?
    private let gitModel = GitSidebarModel()
    private let searchModel = SidebarSearchModel()
    private var overlayPanel: OverlayFileBrowserPanel?
    private var themeObserver: Any?
    private var chromeState: EditorChromeState!
    
    private var lastSidebarExpanded = false
    private var isAnimatingSidebar = false
    private var isAnimatingPythia = false

    /// The shell no longer creates its window — SwiftUI's `Window` scene does.
    /// It adopts the hosting `NSWindow` once the content has mounted, purely for
    /// window chrome (traffic-light geometry, corner rounding, overlay parenting),
    /// for which macOS exposes no public SwiftUI API.
    convenience init() {
        self.init(window: nil)
        setupLiquidGlass()
    }

    // MARK: - Liquid Glass Architecture
    private func setupLiquidGlass() {

        // ── ScopeSettings: load ~/.aether-properties on launch ──
        ScopeSettings.shared.loadGlobal()

        // Editor background is a SwiftUI Material (see EditorContainerView), driven
        // by the theme's glassBlurStrength + glassTint — no AppKit glass view here.
        // ── Sidebar (left pane) ──
        // One roster, three consumers: the AppKit container (pane switching), the
        // panes themselves (each docks the floating tab bar in its own SwiftUI
        // graph via `sidebarTabBar`) and the window titlebar.
        let sidebarTabs: [SidebarTab] = [
            SidebarTab(id: "files",      title: "Files",      symbolName: "folder",                 tooltip: "File Browser"),
            SidebarTab(id: "favourites", title: "Favourites", symbolName: "star",                   tooltip: "Favourite Projects"),
            SidebarTab(id: "search",     title: "Search",     symbolName: "magnifyingglass",        tooltip: "Search"),
            SidebarTab(id: "git",        title: "Git",        symbolName: "arrow.triangle.branch",  tooltip: "Git"),
        ]
        // The chrome must exist before the panes are built — each of them observes
        // it to draw and drive the floating tab bar.
        chromeState = EditorChromeState(sidebarTabs: sidebarTabs)
        sidebarContainer = SidebarContainer(tabs: sidebarTabs)
        sidebarContainer.onTabSelected = { [weak self] id in
            guard let self else { return }
            self.fileBrowser?.view.isHidden = (id != "files")
            self.favouritesVC?.view.isHidden = (id != "favourites")
            self.gitVC?.view.isHidden = (id != "git")
            self.searchVC?.view.isHidden = (id != "search")
            if id == "git" {
                self.chromeState?.sidebarWidth = max(self.chromeState?.sidebarWidth ?? 180, 320)
                self.gitModel.refresh(self.fileBrowser?.rootItem?.url)
            }
        }
 
        // Force-load sidebarContainer.view so loadView() populates contentContainer
        _ = sidebarContainer.view
 
        fileBrowser = FileBrowserViewController()
        fileBrowser.chrome = chromeState
        fileBrowser.setTransparentBackground()
        fileBrowser.onFileOpen = { [weak self] url in
            self?.openFileInTab(url)
        }
        fileBrowser.onFolderOpen = { [weak self] url in
            self?.gitModel.folder = url
            if self?.sidebarContainer.selectedTabId == "git" { self?.gitModel.refresh(url) }
            self?.chromeState?.currentFolder = url
            self?.searchModel.root = url
        }
        sidebarContainer.setContentView(fileBrowser.view, forTabId: "files")

        // ── Favourites (registered AetherCodex projects + ÆtherLink discovery) ──
        favouritesVC = FavouritesHostViewController(chrome: chromeState)
        FavouritesStore.shared.openProject = { [weak self] url in
            self?.fileBrowser?.openFolder(url)
        }
        sidebarContainer.setContentView(favouritesVC.view, forTabId: "favourites")

        gitModel.openFile = { [weak self] url in self?.openFileInTab(url) }
        gitModel.openDiff = { [weak self] title, subtitle, diff, filePath, repoRoot in
            self?.openDiffInTab(title: title, subtitle: subtitle, diff: diff,
                                filePath: filePath, repoRoot: repoRoot)
        }
        gitModel.prepareAI = { [weak self] prompt in
            self?.chromeState?.pythiaVisible = true
            self?.pythiaModel.pendingPrompt = prompt
        }
        gitVC = NSHostingController(rootView: GitSidebarView(model: gitModel, chrome: chromeState))
        sidebarContainer.setContentView(gitVC!.view, forTabId: "git")

        // ── Search (project-scoped filename lookup; Go-To-File panel on demand) ──
        searchModel.open = { [weak self] url in self?.openFileInTab(url) }
        searchVC = NSHostingController(rootView: SidebarSearchView(model: searchModel, chrome: chromeState))
        sidebarContainer.setContentView(searchVC!.view, forTabId: "search")

        // ── Editor (center pane) — tabbed documents ──
        tabsModel = TabsModel()

        // ── Pythia (right pane) — pure SwiftUI PythiaPanel, no WebView ──

        // ── SwiftUI safeAreaBar host (replaces NSSplitViewController) ──
        // safeAreaBar(edge: .top/.leading/.trailing) + .scrollEdgeEffectStyle(.soft)
        // provide native scroll-edge blur on all three edges — something AppKit's
        // NSSplitViewItemAccessoryViewController cannot do (top/bottom only).

        // ── Assemble SwiftUI host as window content ──
        chromeState.sidebarWidth = CGFloat(SessionState.shared.sidebarWidth ?? 180)
        chromeState.pythiaWidth = CGFloat(SessionState.shared.pythiaWidth ?? 280)

        // The SwiftUI bottom safe-area tab bar drives the AppKit pane switcher.
        chromeState.onSidebarTabSelected = { [weak self] id in
            self?.sidebarContainer.selectTab(id: id)
        }
        // Restore the last pane from the session (the old AppKit pill never did).
        if let saved = SessionState.shared.selectedSidebarTab,
           sidebarTabs.contains(where: { $0.id == saved }) {
            chromeState.selectedSidebarTab = saved
            sidebarContainer.selectTab(id: saved)
        }
        
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
        // Both titlebar toggle buttons walk the same guarded paths as their
        // menu counterparts (⌘1/⌘2) — one source of truth for pane state, so the
        // AppKit pane container never drifts out of sync with the SwiftUI bands.
        chromeState.onToggleSidebar = { [weak self] in
            self?.toggleFileBrowser(nil)
        }
        chromeState.onTogglePythia = { [weak self] in
            self?.togglePythia(nil)
        }

        // Breadcrumb navigation: a folder peek drives the sidebar file browser;
        // a file selection opens it in a tab.
        chromeState.navigateFolder = { [weak self] url in
            self?.chromeState?.currentFolder = url
            self?.fileBrowser?.openFolder(url)
        }
        chromeState.openDocument = { [weak self] url in
            self?.openFileInTab(url)
        }

        // Wire the active tab's title into the window chrome. `TabsModel` seeds the
        // first (untitled/flash) tab itself — the old single-editor bootstrap is
        // gone: the AppKit view is never laid out in the SwiftUI hierarchy, so each
        // `EditorTab` runs `newDocument()` explicitly in its `seedIfEmpty()`.
        tabsModel.onActiveTitleChange = { [weak self] title in
            self?.windowTitle = title
            self?.window?.title = title
            self?.chromeState?.title = title
        }
        // Keep the file browser pinned to the active document's folder: switching
        // tabs re-homes the sidebar, so the file you're looking at is always the
        // one whose folder is revealed.
        tabsModel.onActiveTabChange = { [weak self] in
            self?.syncFileBrowserToActiveFile()
        }
        chromeState.title = tabsModel.activeTab?.title ?? "Untitled"

        let containerView = OracleFlipRoot(
            sidebar: sidebarContainer.view,
            pythiaModel: pythiaModel,
            chrome: chromeState,
            tabs: tabsModel
        )
        // SwiftUI's `Window` scene renders this view directly: no NSHostingView,
        // no content view controller, no frame re-assertion battle.
        //
        // The window silhouette is NOT declared here: clipping the root view's
        // SwiftUI layer cuts off the material that must extend behind the traffic
        // lights (the transparent titlebar) and fights the `safeAreaBar` tiling.
        // Rounding lives on the content layer in `applyWindowRounding`, where the
        // native window shadow still follows the window-server arc.
        rootView = AnyView(containerView)

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyGlassTints()
            self?.syncOverlayMode()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveSessionState()
            self?.positionTrafficLights()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveSessionState()
        }
        NotificationCenter.default.addObserver(
            forName: .openFileInEditor, object: nil, queue: .main
        ) { [weak self] note in
            if let request = note.object as? FileLinkRequest {
                self?.openFileInTab(request.url, revealLine: request.line)
            } else if let url = note.object as? URL {
                self?.openFileInTab(url)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .openEntityInTab, object: nil, queue: .main
        ) { [weak self] note in
            guard let request = note.object as? EntityTabRequest else { return }
            self?.openEntityInTab(request)
        }
        // Restore saved session state
        if let lastFolder = SessionState.shared.lastProjectFolder {
            fileBrowser.openFolder(URL(fileURLWithPath: lastFolder))
        }

        // Window chrome (tints, rounding, traffic lights) waits for `adoptHostWindow()`.
    }

    // MARK: - Host Window Adoption

    /// Adopt the `NSWindow` that SwiftUI's `Window` scene created. Called once the
    /// root view has mounted, when the sidebar's AppKit view is inside the live
    /// window hierarchy. Retries briefly — `onAppear` can fire a frame early.
    func adoptHostWindow(attempt: Int = 0) {
        guard window == nil else { return }
        guard let host = sidebarContainer?.view.window
                ?? tabsModel?.activeEditor?.textView.window else {
            if attempt < 40 {
                DispatchQueue.main.async { [weak self] in
                    self?.adoptHostWindow(attempt: attempt + 1)
                }
            }
            return
        }
        window = host
        host.titleVisibility = .hidden
        host.titlebarAppearsTransparent = true
        host.isOpaque = false
        host.backgroundColor = .clear
        host.isMovableByWindowBackground = false
        host.delegate = self

        applyGlassTints()
        applyWindowRounding()
        if let textView = tabsModel?.activeEditor?.textView {
            host.makeFirstResponder(textView)
        }

        restoreSessionFromDisk()
        for arg in CommandLine.arguments.dropFirst()
        where FileManager.default.fileExists(atPath: arg) {
            openFileInTab(URL(fileURLWithPath: arg))
        }
    }

    /// Restore the previous session: open tabs, project folder, pane widths,
    /// overlay mode, and the active theme. (SwiftUI restores the window frame.)
    func restoreSessionFromDisk() {
        let s = SessionState.shared
        let openPaths = s.openTabs.isEmpty ? (s.lastOpenFile.map { [$0] } ?? []) : s.openTabs
        for path in openPaths where FileManager.default.fileExists(atPath: path) {
            openFileInTab(URL(fileURLWithPath: path))
        }
        if let path = s.lastProjectFolder {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                fileBrowser?.openFolder(URL(fileURLWithPath: path))
            }
        }
        if let w = s.sidebarWidth { restoreSidebarWidth(CGFloat(w)) }
        if let w = s.pythiaWidth { restorePythiaWidth(CGFloat(w)) }
        if s.fileBrowserOverlay {
            ThemeSettings.shared.fileBrowserOverlay = true
            syncOverlayMode()
        }
        if let name = s.activeThemeName,
           let index = ThemeRegistry.shared.themes.firstIndex(where: { $0.name == name }) {
            ThemeRegistry.shared.activate(index: index)
        }
    }

    // MARK: - Window rounding + nested traffic lights

    /// Rounds the window content to a Tahoe-style radius and nests the traffic
    /// lights inside the corner. The glass is a SwiftUI `Material` (not an AppKit
    /// `NSVisualEffectView`), so `masksToBounds` on the content layer clips the
    /// rounded silhouette without killing the material's backdrop blur.
    private func applyWindowRounding() {
        guard let window, let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        // The fill is rounded on the content layer — NOT via a SwiftUI
        // `.clipShape` on the root view. A root clip cuts off the material that
        // must extend behind the transparent titlebar (traffic-light background)
        // and fights the `safeAreaBar` bands, which is what made the top go
        // transparent and the sidebars/content clip. `masksToBounds` rounds the
        // visible fill while the native window shadow keeps following the
        // window-server arc — one coherent silhouette, no double border.
        contentView.layer?.cornerRadius = EditorChromeMetrics.windowCornerRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        // Outer glass rim: a hairline border tracing the rounded silhouette so
        // the window reads against any desktop (light or dark). Neutral gray is
        // theme-independent — no re-resolve needed when the appearance flips.
        contentView.layer?.borderWidth = 1.0
        contentView.layer?.borderColor = NSColor(calibratedWhite: 0.5, alpha: 0.45).cgColor
        window.backgroundColor = .clear
        window.hasShadow = true

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
        overlayFB.onFileOpen = { [weak self] url in
            self?.openFileInTab(url)
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
        window?.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
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

        // Tab icon tints
        sidebarContainer?.applyThemeColors(
            tintColor: tabTint,
            accent: theme.glassTintColor,
            dimmed: theme.editorForeground.withAlphaComponent(0.45)
        )
        fileBrowser?.applyForegroundColor(theme.sidebarForeground, accent: theme.sidebarAccent)
        gitModel.theme = theme
        fileBrowser?.setTransparentBackground()

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

        // Open file(s)
        s.lastOpenFile = editorViewController?.currentFile?.path
        s.openTabs = tabsModel?.tabs.compactMap { $0.controller.currentFile?.path } ?? []

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
    }

    /// Restore text view focus when the window becomes key — prevents
    /// the "click to type" friction after dismissing search or switching apps.
    func windowDidBecomeKey(_ notification: Notification) {
        // The startup pass in applyWindowRounding() runs before the window is
        // shown, while the traffic-light buttons aren't yet attached to the live
        // titlebar hierarchy (their superview is nil), so the guard in
        // positionTrafficLights() silently bails and the buttons linger at
        // AppKit's default placement. Re-assert once the window is key, after the
        // titlebar has settled, so the controls nest in the rounded corner.
        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLights()
        }
        // AppKit may run one more titlebar layout pass right after the window
        // becomes key; re-assert a beat later so the final pass wins the race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.positionTrafficLights()
        }
        guard !(editorViewController?.quickSearch.isVisible ?? false) else { return }
        window?.makeFirstResponder(editorViewController?.textView)
    }

    // MARK: - Quick Search (menu routing via responder chain)

    @objc func toggleQuickSearch(_ sender: Any?) {
        editorViewController?.toggleIncrementalSearch()
    }

    @objc func findNext(_ sender: Any?) {
        editorViewController?.searchNavigateForward()
    }

    @objc func findPrevious(_ sender: Any?) {
        editorViewController?.searchNavigateBackward()
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
                openFileInTab(url)
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

    @objc func newTab(_ sender: Any?) {
        tabsModel?.newTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tabs = tabsModel else { return }
        if let entityId = tabs.activeEntityTabId {
            tabs.closeEntity(entityId)
        } else if tabs.tabs.count > 1, let id = tabs.activeTabId {
            tabs.close(id)
        } else {
            window?.performClose(nil)
        }
    }

    @objc func nextTab(_ sender: Any?) {
        tabsModel?.selectNext()
    }

    @objc func previousTab(_ sender: Any?) {
        tabsModel?.selectPrevious()
    }

    /// Open a file into a tab: fills the active untitled tab, otherwise a new one.
    func openFileInTab(_ url: URL, revealLine line: Int? = nil) {
        guard let tabs = tabsModel else { return }
        let tab = tabs.tabForOpening(url)
        tab.controller.openFile(url)
    }

    /// Follow the active document *inside* the current sidebar root. Opening a file
    /// or switching tabs no longer re-homes the browser to the file's folder — the
    /// sidebar stays on the opened project and simply expands + selects + scrolls to
    /// the file. Only when the file lives outside the current root does the browser
    /// fall back to opening its parent folder (there is no other sensible home).
    private func syncFileBrowserToActiveFile() {
        guard let file = tabsModel?.activeTab?.controller.currentFile else { return }
        if fileBrowser?.revealFile(file) == false {
            fileBrowser?.openFolder(file.deletingLastPathComponent())
        }
    }

    /// Open a Magnum Opus task or Salomo seal as a first-class tab.
    func openEntityInTab(_ request: EntityTabRequest) {
        guard let tabs = tabsModel else { return }
        tabs.openEntityTab(request.kind, title: request.title)
        // Leave the oracle-only flip so the tab is immediately visible.
        chromeState?.oracleOnly = false
        saveSessionState()
    }

    /// Open a unified Git diff as a first-class tab in the main editor area.
    func openDiffInTab(title: String, subtitle: String = "", diff: String,
                       filePath: URL? = nil, repoRoot: URL? = nil) {
        guard let tabs = tabsModel else { return }
        tabs.openDiffTab(title: title, subtitle: subtitle, diff: diff,
                         filePath: filePath, repoRoot: repoRoot)
        chromeState?.oracleOnly = false
        saveSessionState()
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

    /// Toggle the Aegis mirror (⌘⇧A). Unfolding the mirror implies its pane:
    /// Aegis has nowhere to breathe while Pythia lies folded away, so a bare
    /// shortcut opens the chamber first and unfolds the mirror second.
    @objc func toggleAegis(_ sender: Any?) {
        guard let chrome = chromeState else { return }
        let opening = !AegisWidgetModel.shared.expanded
        if opening && !chrome.pythiaVisible && !chrome.oracleOnly {
            withAnimation(.easeInOut(duration: 0.2)) {
                chrome.pythiaVisible = true
            }
            saveSessionState()
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            AegisWidgetModel.shared.expanded = opening
        }
        // The mirror is a live reading; unfolding it re-reads the daemon.
        if opening { Task { await AegisWidgetModel.shared.refresh() } }
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

extension MainWindowController {
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

    // MARK: Standard Edit Forwarding

    @objc func deleteLine(_ sender: Any?) { editorViewController?.deleteLine(sender) }
    @objc func insertLineBelow(_ sender: Any?) { editorViewController?.insertLineBelow(sender) }
    @objc func insertLineAbove(_ sender: Any?) { editorViewController?.insertLineAbove(sender) }
    @objc func uppercaseSelection(_ sender: Any?) { editorViewController?.uppercaseSelection(sender) }
    @objc func lowercaseSelection(_ sender: Any?) { editorViewController?.lowercaseSelection(sender) }
    @objc func toggleComment(_ sender: Any?) { editorViewController?.toggleComment(sender) }
    @objc func toggleBlockComment(_ sender: Any?) { editorViewController?.toggleBlockComment(sender) }
    @objc func indentSelection(_ sender: Any?) { editorViewController?.indentSelection(sender) }
    @objc func outdentSelection(_ sender: Any?) { editorViewController?.outdentSelection(sender) }
    @objc func duplicateLine(_ sender: Any?) { editorViewController?.duplicateLine(sender) }
    @objc func moveLineUp(_ sender: Any?) { editorViewController?.moveLineUp(sender) }
    @objc func moveLineDown(_ sender: Any?) { editorViewController?.moveLineDown(sender) }
    @objc func joinLines(_ sender: Any?) { editorViewController?.joinLines(sender) }
    @objc func selectCurrentLine(_ sender: Any?) { editorViewController?.selectCurrentLine(sender) }
    @objc func editEachLineInSelection(_ sender: Any?) { editorViewController?.editEachLineInSelection(sender) }
    @objc func selectNextOccurrence(_ sender: Any?) { editorViewController?.selectNextOccurrence(sender) }
    @objc func selectAllOccurrences(_ sender: Any?) { editorViewController?.selectAllOccurrences(sender) }
    @objc func goToLine(_ sender: Any?) { editorViewController?.goToLine(sender) }
    @objc func toggleInvisibles(_ sender: Any?) { editorViewController?.toggleInvisibles(sender) }

    // MARK: Find & Replace forwarding

    private func prepareFindReplace() -> FindReplaceModel? {
        guard let model = editorViewController?.findReplace else { return nil }
        model.projectRootProvider = { [weak self] in self?.fileBrowser?.rootItem?.url }
        model.openFile = { [weak self] url, line in
            self?.openFileInTab(url, revealLine: line)
        }
        return model
    }

    @objc func showFindDialog(_ sender: Any?) {
        editorViewController?.quickSearch.cancel()
        prepareFindReplace()?.show(replace: false)
    }

    @objc func showFindReplaceDialog(_ sender: Any?) {
        editorViewController?.quickSearch.cancel()
        prepareFindReplace()?.show(replace: true)
    }

    @objc func useSelectionForFind(_ sender: Any?) { prepareFindReplace()?.useSelectionForFind() }
    @objc func findReplaceNext(_ sender: Any?) { prepareFindReplace()?.next() }
    @objc func findReplacePrevious(_ sender: Any?) { prepareFindReplace()?.previous() }

    // MARK: Display toggles

    @objc func toggleLineNumbers(_ sender: Any?) {
        EditorDisplaySettings.shared.showLineNumbers.toggle()
    }

    @objc func toggleWrapColumn(_ sender: Any?) {
        EditorDisplaySettings.shared.showWrapColumn.toggle()
    }

    @objc func setWrapColumnWidth(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let value = item.representedObject as? Int {
            EditorDisplaySettings.shared.wrapColumn = value
        }
    }

    @objc func setWrapColumnOther(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Wrap Column"
        alert.informativeText = "Enter a character column."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.placeholderString = "\(EditorDisplaySettings.shared.wrapColumn)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), n > 0 else { return }
        EditorDisplaySettings.shared.wrapColumn = n
    }

    @objc func goToFile(_ sender: Any?) {
        guard let root = fileBrowser?.rootItem?.url else { return }
        let openPaths = Set((tabsModel?.tabs ?? []).compactMap { $0.controller.currentFile?.path })
        AppScene.shared.showGoToFile(projectRoot: root,
                                     currentURL: editorViewController?.currentFile,
                                     openPaths: openPaths) { [weak self] url in
            self?.openFileInTab(url)
        }
    }

    @objc func searchAether(_ sender: Any?) {
        // TODO: AetherSearchPanel is not yet implemented. The "Search Æther…"
        // (⌥⌘T) menu item is wired but currently defers to the fuzzy Go-to-File
        // palette (⌘T) until the dedicated global-search panel lands.
        goToFile(sender)
    }
    
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = (editorViewController?.effectiveWordWrap ?? false) ? .on : .off
        }
        if menuItem.action == #selector(toggleHighlightCurrentLine(_:)) {
            menuItem.state = ThemeSettings.shared.highlightCurrentLine ? .on : .off
        }
        if menuItem.action == #selector(toggleInvisibles(_:)) {
            let on = editorViewController?.textView.layoutManager?.showsInvisibleCharacters ?? false
            menuItem.state = on ? .on : .off
        }
        if menuItem.action == #selector(toggleLineNumbers(_:)) {
            menuItem.state = EditorDisplaySettings.shared.showLineNumbers ? .on : .off
        }
        if menuItem.action == #selector(toggleWrapColumn(_:)) {
            menuItem.state = EditorDisplaySettings.shared.showWrapColumn ? .on : .off
        }
        if menuItem.action == #selector(toggleAegis(_:)) {
            menuItem.state = AegisWidgetModel.shared.expanded ? .on : .off
        }
        if menuItem.action == #selector(setWrapColumnWidth(_:)) {
            let value = (menuItem.representedObject as? Int) ?? -1
            menuItem.state = (value == EditorDisplaySettings.shared.wrapColumn) ? .on : .off
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