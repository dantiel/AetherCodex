import SwiftUI
import AppKit
import Combine

// MARK: - AppKit bridge

/// Hosts an existing AppKit view as SwiftUI content.
struct AppKitViewHost: NSViewRepresentable {
    let make: () -> NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        let hosted = make()
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hosts SwiftUI content inside a real `NSHostingView` so it participates in
/// AppKit hit-testing as a genuine subview. Without this, a pure-SwiftUI overlay
/// (the Pythia inspector) loses clicks to a sibling `NSViewRepresentable` view
/// (the editor's `NSTextView`) that extends beneath it: AppKit hit-tests real
/// subviews first and only falls back to SwiftUI-drawn content when none claim
/// the point. Wrapping the overlay in an `NSHostingView` makes it a real NSView
/// that `zIndex` can order above the editor, so its buttons take the click.
struct HostedView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        ClickThroughHostingView(rootView: content)
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}

/// An `NSHostingView` that claims every point within its bounds, so transparent
/// SwiftUI regions never leak a click to a sibling NSView behind it (the editor's
/// `NSTextView`). Without this, a panel whose content has empty gaps — a short
/// task list above a blank detail area, the quiet zone under a chat — lets the
/// click fall through to the code view beneath: the "clicks pass through to code
/// view" symptom. Real content (buttons, resize handles) still wins because
/// `super.hitTest` is consulted first; only an empty region falls back to `self`.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        // Collapsed state is width 0 + clipped, so its bounds never contain a
        // point and clicks pass through by design (the inspector folds away).
        return bounds.contains(point) ? self : nil
    }
}

// MARK: - Chrome state

/// Observable state driving the `safeAreaBar` chrome (sidebar + Pythia).
final class EditorChromeState: ObservableObject {
    @Published var sidebarVisible: Bool = true
    @Published var pythiaVisible: Bool = false
    /// Oracle-only mode: the whole window flips like a card, revealing Pythia
    /// alone on the reverse face — the editor chrome folds away entirely.
    @Published var oracleOnly: Bool = false
    @Published var sidebarWidth: CGFloat = 180
    @Published var pythiaWidth: CGFloat = 280
    @Published var title: String = "Untitled"
    /// Current folder shown by the sidebar file browser — anchors the titlebar
    /// breadcrumb (address bar) to the project's navigation state.
    @Published var currentFolder: URL?
    /// Active theme — drives the SwiftUI editor background material + tint.
    @Published var theme: SyntaxTheme = ThemeRegistry.shared.current
    /// Selected sidebar pane (files / favourites / search / git). Drives the
    /// bottom safe-area tab bar and the AppKit `SidebarContainer` switching.
    @Published var selectedSidebarTab: String = "files"
    /// The sidebar's pane roster — shared between the SwiftUI tab bar and the
    /// AppKit container so both speak the same four truths.
    let sidebarTabs: [SidebarTab]
    
    /// Callback to reposition traffic lights when sidebar visibility changes
    var onSidebarVisibilityChange: ((Bool) -> Void)?
    /// Navigate the sidebar file browser to a folder (breadcrumb peek).
    var navigateFolder: ((URL) -> Void)?
    /// Open a document (breadcrumb sibling / path commit targeting a file).
    var openDocument: ((URL) -> Void)?
    /// Switch the sidebar pane (drives SidebarContainer.selectTab).
    var onSidebarTabSelected: ((String) -> Void)?
    /// Toggle the sidebar through the controller's guarded path — the same one
    /// ⌘1 takes. The SwiftUI toggle buttons must not mutate `sidebarVisible`
    /// directly, or the AppKit pane container's collapsed state drifts and the
    /// sheet can reopen empty (content hidden while the band expands).
    var onToggleSidebar: (() -> Void)?
    /// Open/toggle Pythia through the controller's guarded path (⌘2). Keeps the
    /// animation guard + session save consistent with the menu entry.
    var onTogglePythia: (() -> Void)?
    
    init(sidebarTabs: [SidebarTab] = []) {
        self.sidebarTabs = sidebarTabs
        // Observe sidebar visibility changes to trigger animations
        $sidebarVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.onSidebarVisibilityChange?(visible)
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
}

// MARK: - Theme → SwiftUI material mapping

extension SyntaxTheme {
    /// SwiftUI material for the editor background, derived from the resolved glass
    /// blur strength (0.0 = thinnest, 1.0 = heaviest). Replaces the AppKit
    /// `NSGlassEffectView` / `NSVisualEffectView` "material" system — SwiftUI
    /// materials give the same frosted-glass texture, adapt to light/dark
    /// automatically, and compose with `safeAreaBar` + `.scrollEdgeEffectStyle`.
    var editorMaterial: Material {
        let strength = ThemeSettings.shared.resolvedGlassBlurStrength(for: self)
        switch strength {
        case ..<0.2:  return .ultraThin
        case ..<0.4:  return .thin
        case ..<0.6:  return .regular
        case ..<0.8:  return .thick
        default:      return .ultraThick
        }
    }

    /// Tint layered over the editor material (glassTintColor × glassTint).
    var editorGlassTintColor: Color {
        let strength = ThemeSettings.shared.resolvedGlassTint(for: self)
        return Color(nsColor: glassTintColor).opacity(0.3 * strength)
    }

    /// Only the background is translucent; text retains its original opacity.
    var editorBackgroundColor: Color {
        Color(nsColor: editorBackground.withAlphaComponent(1))
            .opacity(ThemeSettings.shared.resolvedEditorBackgroundOpacity(for: self))
    }

    var sidebarMaterial: Material {
        switch ThemeSettings.shared.resolvedSidebarGlassBlurStrength(for: self) {
        case ..<0.2: return .ultraThin
        case ..<0.4: return .thin
        case ..<0.6: return .regular
        case ..<0.8: return .thick
        default: return .ultraThick
        }
    }
}

// MARK: - Editor container (safeAreaBar host)

/// The window's content, expressed in SwiftUI so we can use the native
/// `safeAreaBar(edge:)` API for the top bar, leading sidebar, and trailing
/// Pythia pane. `.scrollEdgeEffectStyle(.soft)` tells the compositor to blur
/// editor content progressively as it scrolls beneath each bar — the same
/// mechanism the `ScrollEdgeSwiftUIDemo` proved for the top edge, now applied
/// to leading/trailing too (which AppKit's `NSSplitViewItemAccessoryViewController`
/// cannot express: it is top/bottom only).
@available(macOS 26.0, *)
struct EditorContainerView: View {
    let sidebar: NSView
    /// Held, NOT observed. The chat model is only ever *handed down* to the
    /// hosted `PythiaPanel`, which observes it itself. Observing it here made
    /// every chat-model change (i.e. every keystroke in the prompt) re-evaluate
    /// this body — and each re-evaluation rebuilt the `HostedView`, replacing
    /// the inspector's `NSHostingView.rootView` inside a `safeAreaBar` band.
    /// macOS 26 re-solves that hosting view's SizeConstraints on every such
    /// replacement and then drops the whole trailing accessory: Pythia vanishes
    /// while `pythiaVisible` still reads `true`, the prompt keeps focus (it is
    /// only clipped away), and the toggle needs two presses to force a clean
    /// layout pass. A reference does not need a subscription to be passed on.
    let pythiaModel: PythiaChatModel
    @ObservedObject var chrome: EditorChromeState
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var displaySettings = EditorDisplaySettings.shared


    /// Resolves the line-number gutter geometry + colors from the active theme
    /// and the document's resolved editor font.
    static func makeGutter(document: EditorDocumentModel, theme: SyntaxTheme,
                           baseFont: NSFont = SyntaxOracle.shared.baseFont) -> EditorGutterStyle {
        // Smaller than the editor face by default; themes may pin an absolute size.
        let numberFont = EditorGutterStyle.rulerFont(for: baseFont, pinnedSize: theme.rulerFontSize)

        // Lightweight cached line count — no full-string split on every keystroke.
        let lineCount = max(document.lineCount, 1)
        let digits = max(2, String(lineCount).count)
        let numberWidth = (String(repeating: "8", count: digits) as NSString)
            .size(withAttributes: [.font: numberFont]).width
        // Shared geometry with `GutterRenderView`: right-aligned numbers keep a
        // number gap (12) + fold gutter (14) to their right, plus a small left
        // inset so the widest number never kisses the sidebar edge. Grows with
        // the digit count of the largest line number.
        // "Hide Line Numbers" collapses the whole gutter column to zero.
        let width = EditorDisplaySettings.shared.showLineNumbers
            ? ceil(EditorGutterStyle.numberLeftPadding + numberWidth + 12 + 14)
            : 0

        return EditorGutterStyle(
            width: width,
            font: numberFont,
            // Exact per-line pitch, measured from a real TextKit layout rather than
            // `defaultLineHeight + lineSpacing` (which is off by ~1pt/line for faces
            // like Monaco and drifts the gutter progressively further down the file).
            lineHeight: EditorGutterStyle.measuredLineHeight(
                for: baseFont,
                lineSpacing: ThemeSettings.shared.resolvedLineSpacing(for: theme)
            ),
            textColor: theme.rulerForeground,
            separatorColor: theme.rulerSeparator,
            backgroundColor: theme.rulerBackground,
            lineHighlightColor: theme.lineHighlight,
            activeLineForeground: theme.editorForeground,
            selectionBackground: theme.gutterSelectionBackground,
            selectionForeground: theme.gutterSelectionForeground,
            selectionBorder: theme.gutterSelectionBorder,
            lineHighlightBorder: theme.lineHighlightBorder
        )
    }

    /// All vertical chrome geometry (title band, tab strip, scroll insets) is
    /// defined once in `EditorChromeMetrics` — see that file for the numbers.

    /// Tab strip is shown for every extra document, or when pinned by settings.
    private var showsTabBar: Bool {
        tabs.showsTabBar
    }

    /// Width of the line-number column the code surface draws at its leading
    /// edge. The title and the tab strip align relative to it, so both track the
    /// gutter as the digit count of the largest line number grows.
    private var gutterWidth: CGFloat {
        guard EditorDisplaySettings.shared.showLineNumbers else { return 0 }
        guard let document = tabs.activeDocument else { return 44 }
        return Self.makeGutter(document: document, theme: chrome.theme).width
    }

    /// Leading gutter width of the surface currently filling the main area. The
    /// titlebar indents the title past it so the filename never sits on the line
    /// numbers — and that column differs per view: the code gutter, the rich-text
    /// ruler, or the diff's double line-number column.
    private var activeSurfaceGutterWidth: CGFloat {
        if let diff = tabs.activeDiffTab {
            return DiffSurface.leadingGutterWidth(for: diff.document)
        }
        if tabs.activeEntityTab != nil {
            return 0
        }
        guard let controller = tabs.activeTab?.controller else { return 0 }
        if controller.imagePreview.isActive { return 0 }
        if controller.htmlPreview.isActive { return 0 }
        if controller.richDocument.active { return RichTextSurface.rulerColumnWidth }
        return gutterWidth
    }

    /// The active document's incremental-search model — `nil` whenever the
    /// visible surface owns no searchable text (entity/diff tabs, image, HTML,
    /// rich-text previews), so the bottom dock is only mounted where Ctrl+S
    /// actually searches something. Read, never observed: see `pythiaModel`.
    private var activeQuickSearch: QuickSearchModel? {
        guard tabs.activeEntityTabId == nil, tabs.activeDiffTabId == nil,
              let controller = tabs.activeTab?.controller,
              !controller.richDocument.active,
              !controller.imagePreview.isActive,
              !controller.htmlPreview.isActive else { return nil }
        return controller.quickSearch
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = EditorPanelWidths(available: geometry.size.width,
                                           sidebar: chrome.sidebarVisible ? chrome.sidebarWidth : nil,
                                           inspector: chrome.pythiaVisible ? chrome.pythiaWidth : nil)
            let showsTabBar = self.showsTabBar
            // Alignment to the document's line-number column: the title is pushed
            // *past* the gutter (the per-view line-number/ruler column) so the
            // filename never sits on the numbers, and the tab strip is pushed past
            // the gutter so its first chip never sits on them either.
            let gutter = gutterWidth
            // Leading edge of the titlebar content. Collapsed: clear the traffic
            // lights (~76pt) so the sidebar toggle sits right of them. Visible:
            // clear the sidebar's full width so the row begins just past it. The
            // gutter offset is applied only to the title so the filename never
            // sits on the line numbers.
            let titlebarLeading: CGFloat = chrome.sidebarVisible ? widths.leading : 76
            let titleGutterInset: CGFloat = chrome.sidebarVisible ? activeSurfaceGutterWidth : 0
            let tabStripLeading: CGFloat = (chrome.sidebarVisible ? widths.leading : 0) + gutter
            ZStack {
                if let diff = tabs.activeDiffTab {
                    DiffSurface(document: diff.document, theme: chrome.theme,
                                topInset: EditorChromeMetrics.chromeInset(showsTabBar: showsTabBar),
                                leading: widths.leading, trailing: widths.trailing)
                        .id(diff.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let entity = tabs.activeEntityTab {
                    EntityTabSurface(tab: entity)
                        .id(entity.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let tab = tabs.activeTab {
                    EditorModeSurface(editor: tab.controller, theme: chrome.theme, document: tab.document,
                                       leading: widths.leading, trailing: widths.trailing,
                                       topInset: EditorChromeMetrics.chromeInset(showsTabBar: showsTabBar),
                                       showWrapColumn: displaySettings.showWrapColumn,
                                       wrapColumn: displaySettings.wrapColumn)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // Status strip + the docked quick-search bar. Declared *first*
                // (innermost) so its band spans only the code column: the leading
                // sidebar and trailing inspector are outer bars that run the full
                // window height and cover this band's left/right flanks. Declared
                // last, the full-width band forced both sidebars to stop above it,
                // leaving the window short of its bottom edge.
                EditorBottomBar(
                    quickSearch: activeQuickSearch,
                    status: tabs.status,
                    theme: chrome.theme
                )
            }
            .safeAreaBar(edge: .leading, spacing: 0) {
                // The sidebar is *always mounted*, exactly like the trailing
                // inspector — collapsed to width 0 instead of being removed from
                // the hierarchy. Conditionally mounting it made macOS 26 re-tile
                // the bar bands on every toggle; that re-tile is what flipped the
                // sibling inspector around (filebrowser "opening on its own" while
                // Pythia closes — the bars fought over the same layout pass).
                // Collapsing preserves state and keeps both panels independent.
                ZStack(alignment: .trailing) {
                    // Continue the gutter through the sheet's shadow margin.
                    // Split off the bottom band rather than stacking two
                    // materials: its paint must match the adjacent status bar.
                    VStack(spacing: 0) {
                        EditorChromeSurface(color: chrome.theme.rulerBackground)
                        EditorStatusSurface(theme: chrome.theme)
                            .frame(height: EditorChromeMetrics.statusBarHeight)
                    }
                    .allowsHitTesting(false)
                    GeometryReader { bounds in
                        let sheet = SidebarSheetGeometry.frame(in: bounds.size)
                        AppKitViewHost { sidebar }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Full sheet height — the floating tab bar is *not*
                            // declared here. Each pane docks it in its own
                            // SwiftUI graph (`sidebarTabBar`), the only place the
                            // scroller hears of the bar: there it insets its
                            // content and the compositor ramps the soft blur
                            // across the whole band. Declared on the AppKit
                            // bridge, the bar is invisible to the panes and only
                            // a few pixels ever blur.
                            .ignoresSafeArea(.container, edges: .bottom)
                            .frame(width: sheet.width, height: sheet.height)
                            .background {
                                Rectangle().fill(chrome.theme.sidebarMaterial)
                                    .overlay(Color(nsColor: chrome.theme.sidebarBackground ?? chrome.theme.rulerBackground)
                                        .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme)))
                            }
                            // Round all four corners: the sheet is a complete
                            // floating card on every edge, so its right side keeps
                            // the same arc as the left instead of docking square.
                            .clipShape(RoundedRectangle(
                                cornerRadius: SidebarSheetGeometry.sheetCornerRadius,
                                style: .continuous))
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: SidebarSheetGeometry.sheetCornerRadius,
                                    style: .continuous)
                                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                            }
                            .shadow(color: .black.opacity(0.12), radius: 7, y: 2)
                            .position(x: sheet.midX, y: sheet.midY)
                    }

                    // Breadcrumb (address bar) + sidebar toggle, living inside
                    // the sheet between the traffic lights and its trailing edge.
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            // The breadcrumb trail is gone — the sidebar now
                            // speaks the opened folder's name only. One line,
                            // one truth: the project the window breathes in.
                            Text(chrome.currentFolder?.lastPathComponent ?? "Kein Ordner")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SidebarToggleButton(chrome: chrome)
                        }
                        .padding(.leading, 100)
                        .padding(.trailing, 16)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 18)

                    SidebarResizeHandle(width: Binding(
                        get: { widths.leading - SidebarSheetGeometry.horizontalInsets },
                        set: { chrome.sidebarWidth = $0 }),
                        limits: 180...widths.sidebarMaximum, direction: 1) {
                            SessionState.shared.sidebarWidth = Double($0)
                        }
                        .frame(width: SidebarSheetGeometry.resizeStripWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .zIndex(10)
                }
                .frame(width: chrome.sidebarVisible ? max(widths.leading, 1) : 0)
                .frame(maxHeight: .infinity)
                .clipped()
                .opacity(chrome.sidebarVisible ? 1 : 0)
                .allowsHitTesting(chrome.sidebarVisible)
                .ignoresSafeArea(.container, edges: .top)
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                // The bar *grows* by the strip band while tabs are visible: the
                // strip then lives inside the bar's blurred region and the
                // editor content begins below it (the top inset the editor
                // would otherwise add for the strip is now part of this bar).
                TopBar(chrome: chrome, tabs: tabs, leadingInset: titlebarLeading, gutterInset: titleGutterInset)
                    // When the strip is shown the bar reserves the *full* strip
                    // band (from the title's lower edge down to the strip's lower
                    // edge) so the glass surface is tall enough to contain it.
                    .padding(.bottom, showsTabBar ? EditorChromeMetrics.tabStripBottom : 0)
            }
            .safeAreaBar(edge: .trailing, spacing: 0) {
                // The background lives OUTSIDE the NSHostingView so the trailing
                // `safeAreaBar` stretches it to the very top of the window — a
                // pure-SwiftUI view honors the bar's top-edge extension, whereas an
                // NSViewRepresentable does not. The interactive content stays inside
                // a real NSHostingView (HostedView) so the inspector remains a
                // genuine NSView above the editor's NSTextView in the AppKit
                // hit-test chain (a pure-SwiftUI overlay would lose clicks).
                //
                // The inspector is *always mounted* — it collapses to width 0
                // (transparent + non-interactive) instead of being removed from the
                // hierarchy. Removing it would destroy PythiaPanel's `@State` (scroll
                // position, focus, draft) and force the whole message list to rebuild
                // on every open; collapsing preserves that state instantly.
                ZStack(alignment: .leading) {
                    // Explicit opaque surface: the inspector's glass + tint background,
                    // and a full-rect hit target for empty regions.
                    Rectangle()
                        .fill(chrome.theme.sidebarMaterial)
                        .overlay(Color(nsColor: chrome.theme.pythia.background)
                            .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme)))
                        // The bottom strip belongs to the code column, so it no
                        // longer paints under the inspector — the inspector's own
                        // glass must therefore carry its column to the window's
                        // bottom edge, or a bare band would show where the strip
                        // used to be.
                        .ignoresSafeArea(.container, edges: .bottom)
                    HostedView {
                        ZStack(alignment: .leading) {
                            PythiaPanel(model: pythiaModel,
                                       topClearance: 8,
                                        onFlip: { chrome.oracleOnly = true },
                                        onClosePythia: { withAnimation(.easeInOut(duration: 0.25)) { chrome.pythiaVisible = false } })
                                .environment(\.markdownThemeName, chrome.theme.name)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .leading) { Divider() }
                            SidebarResizeHandle(width: Binding(
                                get: { widths.trailing }, set: { chrome.pythiaWidth = $0 }),
                                limits: 220...widths.inspectorMaximum, direction: -1) {
                                    SessionState.shared.pythiaWidth = Double($0)
                                }
                                .frame(width: SidebarSheetGeometry.resizeStripWidth)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .zIndex(10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    // Definite width — an `NSHostingView` inside a `safeAreaBar`
                    // band must never be laid out from an ambiguous proposal.
                    // macOS 26 otherwise re-solves its SizeConstraints on every
                    // content change and can drop the accessory entirely: the
                    // inspector disappears even though `pythiaVisible` is true.
                    // The tab strip carries the same cure for the same reason.
                    .frame(width: chrome.pythiaVisible ? max(widths.trailing, 1) : 1)
                    .frame(maxHeight: .infinity)
                }
                // Background fills to the window top even with the strip shown;
                // the inspector *content* clears the strip via its own top inset.
                // Collapsed state is width 0 + opacity 0 + hit-testing off, so the
                // bar reserves no trailing space and never intercepts editor clicks.
                .frame(width: chrome.pythiaVisible ? widths.trailing : 0)
                .frame(maxHeight: .infinity)
                .clipped()
                .opacity(chrome.pythiaVisible ? 1 : 0)
                .allowsHitTesting(chrome.pythiaVisible)
                .zIndex(1)
                .ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .topLeading) {
                if showsTabBar {
                    // The strip lives in the canvas coordinate space — not inside
                    // the top safeAreaBar — so its frame never fights the bar
                    // tiling. A real NSHostingView + zIndex above every sibling
                    // keeps it clickable with Pythia open. It starts *past* the
                    // document's line-number column, so the first chip never
                    // sits on the numbers; collapsed, that is the gutter alone.
                    //
                    // NOTE — no `.ignoresSafeArea` here: two `NSHostingView`s
                    // (this strip + the trailing Pythia inspector) that BOTH
                    // carry `ignoresSafeArea(.top)` re-evaluate in tandem when
                    // `showsTabBar` grows the top bar. On macOS 26 that
                    // ping-pong is an endless `SizeConstraints` layout loop
                    // (100% CPU freeze) — only with Pythia open. The strip's
                    // explicit frame + paddings already place it in the
                    // ignoresSafeArea overlay, so the modifier is redundant.
                    HostedView { EditorTabBar(tabs: tabs) }
                        // Definite, finite frame — the NSHostingView's
                        // SizeConstraints must be stable: an ambiguous width from
                        // the overlay proposal + `.ignoresSafeArea()` drove macOS 26
                        // into an endless `SizeConstraints.update(from:)` →
                        // `setNeedsUpdate` loop (the "too many Update Constraints
                        // passes" abort) the moment the strip appears on New Tab.
                        .frame(width: max(geometry.size.width - tabStripLeading - widths.trailing - 8, 1),
                               height: EditorChromeMetrics.tabBarBand)
                        .padding(.leading, tabStripLeading)
                        // Code-area width only: the strip stops at the Pythia
                        // inspector's leading edge, never running across it.
                        .padding(.trailing, 8)
                        .padding(.top, EditorChromeMetrics.tabStripTop - 4)
                        .zIndex(2)
                }
            }
        }
    }
}

// MARK: - Oracle flip card

/// The window's true content — a flip card. Front face = the code editor
/// (chrome and all); reverse face = Pythia alone. `oracleOnly` turns the card
/// over: the editor does not slide or maximize, it *turns away*.
///
/// The `.behindWindow` desktop backdrop (`WindowBackdrop`) is the one layer that
/// must never be 3D-transformed — rotating it re-samples the desktop every frame
/// and froze the app. It therefore lives *behind* the card, static and shared by
/// both faces, while only the content (editor / Pythia) actually turns over.
@available(macOS 26.0, *)
struct OracleFlipRoot: View {
    let sidebar: NSView
    /// Reference only — see `EditorContainerView`. Observing it here would
    /// re-evaluate the flip card (and thus re-mount the front face's hosting
    /// views) on every chat-model change: the same bar-drop that folds the
    /// inspector away.
    let pythiaModel: PythiaChatModel
    @ObservedObject var chrome: EditorChromeState
    @ObservedObject var tabs: TabsModel

    /// Flip angle: 0 = editor, 180 = Pythia alone. Driven by `oracleOnly`.
    @State private var degrees: Double = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Desktop glass — an isotropic frosted blur of what sits behind the
                // window, so it correctly stays put while the window's *content*
                // turns over above it. It must never be 3D-transformed: rotating
                // the `.behindWindow` material re-samples the desktop every frame
                // and froze the app.
                WindowBackdrop(strength: ThemeSettings.shared.resolvedGlassBlurStrength(for: chrome.theme))
                    .ignoresSafeArea()

                // The flip card is the ENTIRE window — exactly the same bounds as
                // the glass above — so the whole window turns over, not a content
                // region. Any smallest window becomes a sole Pythia chamber.
                ZStack {
                    // Front face: the code editor with all its chrome + glass tint.
                    EditorContainerView(sidebar: sidebar,
                                        pythiaModel: pythiaModel, chrome: chrome,
                                        tabs: tabs)
                        .background(chrome.theme.editorGlassTintColor)
                        .opacity(degrees < 90 ? 1 : 0)
                        .allowsHitTesting(degrees < 90)
                        .rotation3DEffect(.degrees(degrees), axis: (x: 0, y: 1, z: 0),
                                          anchor: .center, perspective: 0.6)

                    // Reverse face: Pythia alone — pre-rotated 180° so it reads
                    // correctly as it turns toward the user.
                    OracleOnlyView(pythiaModel: pythiaModel, chrome: chrome)
                        .opacity(degrees >= 90 ? 1 : 0)
                        .allowsHitTesting(degrees >= 90)
                        .rotation3DEffect(.degrees(degrees - 180), axis: (x: 0, y: 1, z: 0),
                                          anchor: .center, perspective: 0.6)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onChange(of: chrome.oracleOnly) { _, flipped in
            withAnimation(.easeInOut(duration: 0.62)) {
                degrees = flipped ? 180 : 0
            }
        }
    }
}

/// The reverse face of the flip card — Pythia stands alone, filling the window.
@available(macOS 26.0, *)
private struct OracleOnlyView: View {
    /// Reference only — the panel observes the model itself.
    let pythiaModel: PythiaChatModel
    @ObservedObject var chrome: EditorChromeState

    private var palette: PythiaPalette { chrome.theme.pythia }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Only the Pythia tint lives here; the desktop backdrop is shared,
            // static, and lives behind the flip card in `OracleFlipRoot`.
            Color(nsColor: chrome.theme.pythia.background)
                .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme))

            PythiaPanel(model: pythiaModel)
                .environment(\.markdownThemeName, chrome.theme.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            flipBackButton
        }
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
    }

    private var flipBackButton: some View {
        Button {
            chrome.oracleOnly = false
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foregroundColor)
        .help("Return to Editor")
        .padding(.leading, 80)
        .padding(.top, 8)
    }
}

private struct EditorModeSurface: View {
    let editor: EditorViewController
    let theme: SyntaxTheme
    @ObservedObject var document: EditorDocumentModel
    @ObservedObject var rich: RichTextDocument
    @ObservedObject var imageModel: ImagePreviewModel
    @ObservedObject var htmlModel: HTMLPreviewModel
    var leading: CGFloat
    var trailing: CGFloat
    /// Extra scroll-content inset above the first line, for chrome rows that sit
    /// above the editor surface (the tab strip). Zero when no strip is shown.
    var topInset: CGFloat
    var showWrapColumn: Bool
    var wrapColumn: Int

    init(editor: EditorViewController, theme: SyntaxTheme, document: EditorDocumentModel,
          leading: CGFloat = 0, trailing: CGFloat = 0, topInset: CGFloat = 0,
          showWrapColumn: Bool = false, wrapColumn: Int = 80) {
        self.editor = editor
        self.theme = theme
        self.document = document
        self.rich = editor.richDocument
        self.imageModel = editor.imagePreview
        self.htmlModel = editor.htmlPreview
        self.leading = leading
        self.trailing = trailing
        self.topInset = topInset
        self.showWrapColumn = showWrapColumn
        self.wrapColumn = wrapColumn
    }

    var body: some View {
        if imageModel.isActive {
            ImagePreviewSurface(model: imageModel, theme: theme, topInset: topInset)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else if htmlModel.isActive {
            HTMLPreviewSurface(model: htmlModel, theme: theme, topInset: topInset, onShowSource: editor.showHTMLSource)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else if rich.active {
            RichTextSurface(document: rich, theme: theme, sidebarClosed: leading == 0, topInset: topInset)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else {
            TextKit2ScrollSurface(attributedString: document.attributedString,
                                   backgroundColor: theme.editorBackgroundColor,
                                   gutter: EditorContainerView.makeGutter(document: document, theme: theme),
                                   leadingChromeWidth: leading, trailingChromeWidth: trailing,
                                   topChromeInset: topInset,
                                   sharedTextStorage: editor.textStorage, existingEditor: editor.textView,
                                   searchModel: editor.quickSearch,
                                   findReplace: editor.findReplace,
                                   showWrapColumn: showWrapColumn,
                                   wrapColumn: wrapColumn,
                                   lineCount: document.lineCount, maxLineWidth: document.maxLineWidth)
        }
    }
}

// MARK: - Editor tab bar

/// Tab strip rendered just beneath the title bar, above the editor surface.
/// Hidden when there is only one tab unless the user enabled "always show".
@available(macOS 26.0, *)
struct EditorTabBar: View {
    @ObservedObject var tabs: TabsModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs.tabs) { tab in
                    EditorTabChip(tab: tab, isActive: tab.id == tabs.activeTabId && tabs.activeEntityTabId == nil) {
                        tabs.select(tab.id)
                    } onClose: {
                        if tabs.tabs.count > 1 { tabs.close(tab.id) }
                    }
                }
                ForEach(tabs.entityTabs) { tab in
                    EntityTabChip(tab: tab, isActive: tab.id == tabs.activeEntityTabId) {
                        tabs.selectEntity(tab.id)
                    } onClose: {
                        tabs.closeEntity(tab.id)
                    }
                }
                ForEach(tabs.diffTabs) { tab in
                    DiffTabChip(tab: tab, isActive: tab.id == tabs.activeDiffTabId) {
                        tabs.selectDiff(tab.id)
                    } onClose: {
                        tabs.closeDiff(tab.id)
                    }
                }
                newTabButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // Transparent: the strip floats above the progressive blur under the
        // title bar instead of carving its own material band. The scroll-edge
        // effect behind it blurs scrolled code as it travels up underneath.
    }

    private var newTabButton: some View {
        Button {
            tabs.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New Tab")
    }
}

@available(macOS 26.0, *)
private struct EntityTabChip: View {
    @ObservedObject var tab: EntityDocumentTab
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(tab.kind.glyph)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(isActive ? Color.primary.opacity(0.72) : Color.secondary)
            Text(tab.title)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            if hovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, hovering || isActive ? 4 : 9)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.regularMaterial)
                               : hovering ? AnyShapeStyle(.quaternary.opacity(0.5))
                               : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.white.opacity(0.14)
                                       : hovering ? Color.white.opacity(0.08)
                                       : Color.clear, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

@available(macOS 26.0, *)
private struct DiffTabChip: View {
    @ObservedObject var tab: DiffTab
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(isActive ? Color.primary.opacity(0.72) : Color.secondary)
            Text(tab.title)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            if hovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Diff")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, hovering || isActive ? 4 : 9)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.regularMaterial)
                               : hovering ? AnyShapeStyle(.quaternary.opacity(0.5))
                               : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.white.opacity(0.14)
                                       : hovering ? Color.white.opacity(0.08)
                                       : Color.clear, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

@available(macOS 26.0, *)
private struct EditorTabChip: View {
    @ObservedObject var tab: EditorTab
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    private var displayName: String {
        let t = tab.title
        if t.hasSuffix(" •") { return String(t.dropLast(2)) }
        return t
    }

    /// Safari/Finder-style pill: quiet at rest, filled when active, the close
    /// button appears only while hovered or selected.
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: FileIcon.symbol(for: tab.controller.currentFile))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(isActive ? Color.primary.opacity(0.72) : Color.secondary)
            Text(displayName)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            if tab.isDirty {
                Circle().fill(Color.accentColor.opacity(0.9)).frame(width: 6, height: 6)
            }
            if hovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, hovering || isActive ? 4 : 9)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.regularMaterial)
                               : hovering ? AnyShapeStyle(.quaternary.opacity(0.5))
                               : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.white.opacity(0.14)
                                       : hovering ? Color.white.opacity(0.08)
                                       : Color.clear, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Title menu item

/// Closure-backed `NSMenuItem`: lets the title's native pop-up menu (left-click)
/// reuse the same commands as the SwiftUI context menu (right-click) without a
/// target/selector pair.
private final class TitleMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @objc private func fire() { handler() }
}

// MARK: - Top bar

/// Minimal toolbar-equivalent for the top `safeAreaBar`.
/// SwiftUI materials provide the glass blur (replacing the AppKit NSToolbar
/// title item + the removed floating-panel glass).
struct TopBar: View {
    @ObservedObject var chrome: EditorChromeState
    @ObservedObject var tabs: TabsModel
    /// Left edge of the titlebar content, in window coordinates. Collapsed: the
    /// sidebar toggle starts just past the traffic lights. Visible: the whole row
    /// begins at the sidebar's right edge.
    var leadingInset: CGFloat = 76
    /// Extra leading pad on the title so the filename never sits on line numbers.
    var gutterInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            // The sidebar toggle lives in the sidebar header while it is open
            // (next to the breadcrumb); only when collapsed does it appear here,
            // right of the traffic lights, so it stays reachable.
            if !chrome.sidebarVisible {
                sidebarToggle
            }

            titleGlyph
                .padding(.leading, gutterInset + 12)
            titleLabel

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 160)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .offset(y: -28)
        .overlay(alignment: .trailing) {
            trailingControls
                .padding(.trailing, 12)
        }
    }

    private var sidebarToggle: some View {
        SidebarToggleButton(chrome: chrome)
    }

    /// The window title — always the active document's name; the breadcrumb never
    /// replaces it.
    private var titleLabel: some View {
        Text(chrome.title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 8)
    }

    @ViewBuilder private var titleGlyph: some View {
        if let entity = tabs.activeEntityTab {
            Text(entity.kind.glyph).font(.system(size: 11))
        } else {
            Image(systemName: FileIcon.symbol(for: activeFileURL))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    /// Only a document tab has a file behind it; an entity tab (task/seal) has none.
    private var activeFileURL: URL? {
        tabs.activeEntityTab == nil ? tabs.activeTab?.controller.currentFile : nil
    }

    /// Right-aligned controls in the title row: "Open Pythia" while it is closed,
    /// then its own maximize (flip) + hide (close) buttons once it is open — so
    /// Pythia's chrome lives in the shared titlebar, above the tab strip.
    @ViewBuilder private var trailingControls: some View {
        HStack(spacing: 8) {
            EditorModeControls(tabs: tabs)
                .offset(y: -26)
            if !chrome.pythiaVisible {
                openPythiaButton
                   .offset(y: -28)
            }
        }
    }

    /// Minimal launcher shown in the titlebar only while Pythia is closed.
    private var openPythiaButton: some View {
        Button {
            chrome.onTogglePythia?()
        } label: {
            Image(systemName: "rectangle.righthalf.inset.filled")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.theme.pythia.accentColor)
        .help("Open Pythia")
        .padding(2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}


/// Forward mode switches in the titlebar's trailing slot — "Rich Text" and
/// "Preview" appear only while the plain source surface is active, so a file's
/// WYSIWYG / HTML faces stay one click from the shared chrome row. The rich and
/// HTML faces carry their own inline "Source" control, so no reverse button here.
private struct EditorModeControls: View {
    @ObservedObject var tabs: TabsModel

    var body: some View {
        if let tab = tabs.activeTab, tabs.activeEntityTab == nil {
            EditorModeButtons(tab: tab)
        }
    }
}

/// Per-tab mode buttons. Observes the tab (for file-type changes) plus the three
/// mode objects (so the buttons re-render the moment the surface flips).
private struct EditorModeButtons: View {
    @ObservedObject var tab: EditorTab
    @ObservedObject var rich: RichTextDocument
    @ObservedObject var html: HTMLPreviewModel
    @ObservedObject var image: ImagePreviewModel

    init(tab: EditorTab) {
        self.tab = tab
        _rich = ObservedObject(wrappedValue: tab.controller.richDocument)
        _html = ObservedObject(wrappedValue: tab.controller.htmlPreview)
        _image = ObservedObject(wrappedValue: tab.controller.imagePreview)
    }

    private var editor: EditorViewController { tab.controller }

    var body: some View {
        HStack(spacing: 2) {
            if rich.active {
                modeButton("Source", system: "chevron.left.forwardslash.chevron.right", action: editor.showMarkdownSource)
            } else if html.isActive {
                modeButton("Source", system: "chevron.left.forwardslash.chevron.right", action: editor.showHTMLSource)
            } else if !image.isActive {
                if editor.supportsRichText {
                    modeButton("Rich Text", system: "doc.richtext", action: editor.showRichText)
                }
                if editor.supportsHTML {
                    modeButton("Preview", system: "eye", action: editor.previewHTML)
                }
            }
        }
    }

    private func modeButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

private struct SidebarToggleButton: View {
    @ObservedObject var chrome: EditorChromeState
    var body: some View {
        Button {
            chrome.onToggleSidebar?()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .foregroundStyle(Color(nsColor: chrome.theme.sidebarAccent))
        .help("Toggle Sidebar")
    }
}
