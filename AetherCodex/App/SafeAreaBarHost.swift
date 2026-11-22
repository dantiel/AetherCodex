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

// MARK: - Pythia status band

/// The bottom status band under Pythia: context (active model + thinking level),
/// the session's token usage, and cost. Observes `PythiaUsageModel` — a separate
/// observable from the chat model — so it re-renders only when the accounting
/// changes, never on prompt keystrokes (the macOS 26 bar-drop guard).
private struct PythiaStatusBar: View {
    @ObservedObject var usage: PythiaUsageModel
    let theme: SyntaxTheme

    var body: some View {
        HStack(spacing: 8) {
            Text(contextLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(tokenLabel)
            Text("·").foregroundStyle(.tertiary)
            Text(costLabel)
            if usage.allTimeCost > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("Σ \(Self.usd(usage.allTimeCost))")
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: EditorChromeMetrics.statusBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { EditorStatusSurface(theme: theme) }
        .allowsHitTesting(false)
    }

    private var contextLabel: String {
        var parts = [usage.model]
        if usage.thinking != "normal", !usage.thinking.isEmpty {
            parts.append(usage.thinking)
        }
        if usage.contextTurns > 0 {
            parts.append("\(usage.contextTurns)t")
        }
        return parts.joined(separator: " · ")
    }

    private var tokenLabel: String {
        Self.compact(usage.sessionTokens) + " tok"
    }

    private var costLabel: String {
        Self.usd(usage.sessionCost)
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func usd(_ v: Double) -> String {
        String(format: "$%.4f", v)
    }
}

// MARK: - Chrome state

/// Observable state driving the `safeAreaBar` chrome (sidebar + Pythia).
final class EditorChromeState: ObservableObject {
    @Published var sidebarVisible: Bool = true
    @Published var pythiaVisible: Bool = false
    /// Bottom status band (language/position, docked sidebar strip, Pythia
    /// accounting). Hidden via View → Status Bar. Per-window, not persisted —
    /// mirrors `sidebarVisible`/`pythiaVisible`, which reset on launch.
    @Published var statusBarVisible: Bool = true
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
    /// Flip the window into/out of oracle-only through the controller's path
    /// (⌘3). The buttons must not set `oracleOnly` directly: the controller also
    /// folds the side panel away and restores it on the way back.
    var onToggleOracleOnly: (() -> Void)?
    
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

    /// Sidebar accent tint — the per-theme `sidebarAccent` hue, as *pigment*.
    ///
    /// The leading pane is the *only* surface that carries it; the line-number
    /// gutter keeps its own `rulerBackground` so the two never read as one
    /// painted column. Strength is a pigment fraction (`paneTintStrength`), never
    /// the theme's surface opacity — that is a paint value and would bury the
    /// glass beneath an opaque card.
    var sidebarAccentTintColor: Color {
        Color(nsColor: sidebarAccent)
            .opacity(ThemeSettings.shared.resolvedSidebarAccentTint(for: self))
    }

    /// Pythia inspector glass tint — the chamber's own ground
    /// (`pythia.background`, declared per theme), *not* a derived complementary
    /// hue: a rotated hue reads as a colour foreign to the theme. Same pigment
    /// fraction as the leading sheet, so the two panes frost identically and
    /// differ only in hue.
    var pythiaGlassTintColor: Color {
        Color(nsColor: pythia.background)
            .opacity(ThemeSettings.shared.resolvedPythiaGlassTint(for: self))
    }
}

// MARK: - Focus-stable Liquid Glass

/// Window key state, published into the view tree.
///
/// Liquid Glass has an *inactive* appearance: while the window is not key its
/// frost turns lighter and drains toward grey. A low-alpha pigment laid over that
/// frost survives, but the hue is washed out — the pane reads colourless exactly
/// when the window loses focus. Knowing the state lets the pigment answer.
private struct WindowIsKeyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowIsKey: Bool {
        get { self[WindowIsKeyKey.self] }
        set { self[WindowIsKeyKey.self] = newValue }
    }
}

/// Reports the hosting window's key state (and keeps reporting it).
struct WindowKeyObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.onChange = onChange
        (nsView as? ProbeView)?.report()
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { report(); return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                object: window, queue: .main) { [weak self] _ in
                self?.onChange?(true)
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                                object: window, queue: .main) { [weak self] _ in
                self?.onChange?(false)
            })
            report()
        }

        func report() {
            onChange?(window?.isKeyWindow ?? true)
        }
    }
}

/// Frost and pigment, kept in two layers on purpose.
///
/// `glassEffect(.regular.tint(_:))` hands the colour to the *glass layer* itself,
/// and macOS desaturates that layer while the window is not key. On reactivation
/// the layer is not re-resolved — the pane keeps the drained one and reads
/// colourless until something unrelated rebuilds it (and a forced rebuild via a
/// fresh identity only repaints the same drained appearance). So the frost stays
/// **untinted**, and the hue is drawn as an ordinary colour fill above it: a plain
/// SwiftUI layer that no focus transition touches — the same reason the line-number
/// gutter, drawn that way all along, never loses its pigment.
///
/// Order matters as much as separation: the frost is attached to its own overlay
/// view, the pigment to the *next* overlay, so the hue is never a child of the
/// glass-bearing view. And because an inactive window's frost lightens, the
/// pigment gains weight while the window is not key instead of going pale.
///
/// The glass is *not* overpainted: the pigment is a fraction of the accent
/// (see `paneTintStrength`), so the frost, the refraction and the desktop behind
/// it all still read through.
@available(macOS 26.0, *)
private struct PigmentedGlass<S: Shape>: ViewModifier {
    let tint: Color
    let shape: S

    @Environment(\.windowIsKey) private var windowIsKey

    func body(content: Content) -> some View {
        content
            .overlay { Color.clear.glassEffect(.regular, in: shape) }
            .overlay { shape.fill(tint).opacity(windowIsKey ? 1 : 1.85) }
    }
}

@available(macOS 26.0, *)
extension View {
    /// One frost, one pigment layer that survives focus changes. See
    /// `PigmentedGlass`.
    func pigmentedGlass<S: Shape>(tint: Color, in shape: S) -> some View {
        modifier(PigmentedGlass(tint: tint, shape: shape))
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
    /// Transient TextMate-style readout of the last font-size change (⌘+/⌘-),
    /// shown as a percentage of the 13pt default. Nil while hidden.
    @State private var fontSizeHudPercent: Int? = nil
    @State private var fontSizeHudTask: Task<Void, Never>? = nil
    /// Whether the hosting window is key. Published into the tree so the pane
    /// pigment can answer the glass's inactive (drained) appearance.
    @State private var windowIsKey = true


    /// Resolves the line-number gutter geometry + colors from the active theme
    /// and the document's resolved editor font.
    static func makeGutter(document: EditorDocumentModel, theme: SyntaxTheme,
                           baseFont: NSFont = SyntaxOracle.shared.baseFont,
                           lineCount override: Int? = nil) -> EditorGutterStyle {
        // Smaller than the editor face by default; themes may pin an absolute size.
        let numberFont = EditorGutterStyle.rulerFont(for: baseFont, pinnedSize: theme.rulerFontSize)

        // Lightweight cached line count — no full-string split on every keystroke.
        // The chrome passes its published mirror as `override`: it must see the
        // same width the surface draws, even before the document notifies.
        let lineCount = max(override ?? document.lineCount, 1)
        let digits = max(2, String(lineCount).count)
        let numberWidth = (String(repeating: "8", count: digits) as NSString)
            .size(withAttributes: [.font: numberFont]).width
        // Shared geometry with `GutterRenderView`: right-aligned numbers keep a
        // number gap (12) + fold gutter (14) to their right, plus a small left
        // inset so the widest number never kisses the sidebar edge. Grows with
        // the digit count of the largest line number.
        // "Hide Line Numbers" keeps the marker lane (fold + annotation gutter)
        // but stops drawing digits — the column must not collapse, or folds and
        // future annotation markers would have nowhere to sit.
        let showsNumbers = EditorDisplaySettings.shared.showLineNumbers
        let width = showsNumbers
            ? ceil(EditorGutterStyle.numberLeftPadding + numberWidth + 12 + 14)
            : EditorGutterStyle.markerColumnWidth

        return EditorGutterStyle(
            width: width,
            showsNumbers: showsNumbers,
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
            // The gutter is its own themed surface — `rulerBackground`, never the
            // sidebar accent. The accent belongs to the sidebar panel alone; the
            // number column draws the theme's declared ruler pigment over the
            // shared glass so scrolled code still blurs through it.
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
        // The diff surface numbers twice (old + new side); its leading column is
        // wider than any code gutter and grows with *its* line numbers.
        if let diff = tabs.activeDiffTab {
            return DiffSurface.leadingGutterWidth(for: diff.document)
        }
        // Rich text and images own a ruler column of their own: the chrome must
        // clear it exactly like a number gutter.
        if let controller = tabs.activeTab?.controller {
            if controller.imagePreview.isActive { return ImagePreviewSurface.rulerColumnWidth }
            if controller.richDocument.active { return RichTextSurface.rulerColumnWidth }
        }
        guard EditorDisplaySettings.shared.showLineNumbers else {
            // The marker lane survives hidden numbers — the title/tab strip keep
            // aligning to the column that is still there.
            return EditorGutterStyle.markerColumnWidth
        }
        guard let document = tabs.activeDocument else { return 44 }
        return Self.makeGutter(document: document, theme: chrome.theme,
                               lineCount: max(tabs.activeLineCount, document.lineCount)).width
    }


    /// Surfaces that paint the sidebar band themselves: the diff, the rich-text
    /// ruler column and the image ruler column all span the window edge like the
    /// code surface does. Frosting that band a second time would grey the accent.
    private var surfaceDrawsOwnLeadingBand: Bool {
        if tabs.activeDiffTab != nil { return true }
        guard let controller = tabs.activeTab?.controller else { return false }
        return controller.richDocument.active || controller.imagePreview.isActive
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

    /// Flash the font-size readout for a beat, cancelling any in-flight hide so
    /// rapid ⌘+/⌘- taps always show the freshest percentage.
    private func flashFontSizeHud(_ percent: Int) {
        fontSizeHudTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            fontSizeHudPercent = percent
        }
        fontSizeHudTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                fontSizeHudPercent = nil
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = EditorPanelWidths(available: geometry.size.width,
                                           sidebar: chrome.sidebarVisible ? chrome.sidebarWidth : nil,
                                           inspector: chrome.pythiaVisible ? chrome.pythiaWidth : nil)
            let showsTabBar = self.showsTabBar
            // Alignment to the document's line-number column: the tab strip is
            // pushed past the gutter so its first chip never sits on the numbers.
            // (The title now lives in the native toolbar, which clears the
            // sidebar/gutter through `OracleFlipRoot.toolbarTitle`.)
            let gutter = gutterWidth
            let tabStripLeading: CGFloat = (chrome.sidebarVisible ? widths.leading : 0) + gutter
            ZStack {
                if let diff = tabs.activeDiffTab {
                    DiffSurface(document: diff.document, theme: chrome.theme,
                                topInset: EditorChromeMetrics.chromeInset(showsTabBar: showsTabBar),
                                leading: widths.leading, trailing: widths.trailing)
                        .id(diff.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let entity = tabs.activeEntityTab {
                    EntityTabSurface(
                        tab: entity,
                        topInset: EditorChromeMetrics.chromeInset(showsTabBar: showsTabBar)
                    )
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
            // The quick-search pill lives inside the code surface itself (see
            // `TextKit2ScrollSurface`), where the real column geometry is known:
            // anchoring it here to window-estimated widths is what let an open
            // sidebar drag it off the text it searches.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // Status strip only. Declared *first* (innermost) so its band
                // spans only the code column: the leading sidebar and trailing
                // inspector are outer bars that run the full window height and
                // cover this band's left/right flanks.
                EditorBottomBar(
                    status: tabs.status,
                    theme: chrome.theme,
                    showStatusBar: chrome.statusBarVisible
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
                    // The band+gutter plane is drawn by the code surface itself,
                    // between the scrolling text and the numbers — the only place
                    // it can sit. So the band must NOT paint a second surface:
                    // two materials at two origins is exactly what read as a seam.
                    // Surfaces that stop short of the band (diff, entity, image,
                    // HTML, rich text) still need a backdrop here.
                    ZStack(alignment: .bottom) {
                        // The code surface and the diff surface each draw the
                        // band+gutter plane themselves, between the scrolling
                        // content and the numbers. A second material here would be
                        // the seam again — only surfaces that stop short of the
                        // band (entity, image, HTML, rich text) need this backdrop.
                        // The code surface, the diff, the rich-text ruler and
                        // the image ruler each draw the band+gutter plane
                        // themselves. Only surfaces that stop short of the band
                        // (entity, HTML preview) still need this backdrop — a
                        // second material under a surface that already carries
                        // one is exactly the seam.
                        if activeQuickSearch == nil && !surfaceDrawsOwnLeadingBand {
                            // The leading band carries the *accent* glass tint —
                            // the same `.regular.tint` as the sheet's own surface
                            // below. A flat `sidebarBackground` paint here was a
                            // second, nearly opaque surface that drowned the accent
                            // hue (Monokai's sidebarBackground is brownish `0x715758`,
                            // while the accent is pink `0xFB9BBE`) — the sheet's
                            // translucent glass sampled *that*, not the editor, so
                            // the pane read brown instead of accent. Mirroring the
                            // trailing inspector (complementary tint, no opaque
                            // backdrop) keeps the two panes true siblings.
                            Rectangle()
                                .fill(.clear)
                                .pigmentedGlass(tint: chrome.theme.sidebarAccentTintColor,
                                                in: Rectangle())
                        }
                        if chrome.statusBarVisible {
                            EditorStatusSurface(theme: chrome.theme)
                                .frame(height: EditorChromeMetrics.statusBarHeight)
                                // The strip behind the sheet docks only on its right
                                // edge (where it meets the code column's status bar);
                                // its far-left sliver is a pointless artifact at the
                                // window corner, so fade it out toward the leading
                                // edge instead of painting a full-width band.
/*                                .mask {
                                    LinearGradient(stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.65),
                                        .init(color: .white, location: 0.95),
                                        .init(color: .white, location: 1)
                                    ], startPoint: .leading, endPoint: .trailing)
                                }
*/                        }
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
                            // The sheet is its own floating card, as it always
                            // was. The unified band+gutter plane lives *behind*
                            // it (drawn by the code surface, with this card's
                            // footprint punched out via SidebarCardHole), so the
                            // card must not frost the code a second time: it
                            // carries one glass and one accent tint — a distinct
                            // hue lifted off the gutter's own ruler pigment.
                            .background {
                                // Real Liquid Glass, not an AppKit `Material`: a
                                // material sample of the sheet's own paint read as
                                // a flat card. The theme's sidebar accent rides the
                                // compositor's glass as a *tint* only — the frost
                                // beneath stays visible.
                                Rectangle()
                                    .fill(.clear)
                                    .pigmentedGlass(tint: chrome.theme.sidebarAccentTintColor,
                                                    in: RoundedRectangle(
                                                        cornerRadius: SidebarSheetGeometry.sheetCornerRadius,
                                                        style: .continuous))
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
                    // Glass above, status surface below — the bottom strip now
                    // runs continuously under Pythia too, mirroring the leading
                    // sidebar. The inspector's glass therefore stops one strip
                    // above the window's bottom edge instead of reaching it.
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(.clear)
                            .pigmentedGlass(tint: chrome.theme.pythiaGlassTintColor,
                                            in: Rectangle())
                        if chrome.statusBarVisible {
                            PythiaStatusBar(usage: pythiaModel.usage, theme: chrome.theme)
                        }
                    }
                    .allowsHitTesting(false)
                    HostedView {
                        ZStack(alignment: .leading) {
                            PythiaPanel(model: pythiaModel,
                                       topClearance: EditorChromeMetrics.titleBarBand)
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
                        // The NSHostingView does not inherit the bar's top-edge
                        // extension, so the content must ignore the window's top
                        // safe area itself to sit behind the transparent toolbar.
                        .ignoresSafeArea(edges: .top)
                        // Stop the inspector content one strip above the bottom
                        // edge, so the status surface painted beneath it stays
                        // visible instead of being covered by the input bar.
                        .padding(.bottom, chrome.statusBarVisible ? EditorChromeMetrics.statusBarHeight : 0)
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
            // Font-size HUD (⌘+/⌘-/⌘0): a transient percentage readout centred
            // over the editor. Inert — it must never steal a click or scroll.
            .overlay {
                if let percent = fontSizeHudPercent {
                    Text("\(percent)%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: displaySettings.fontSizeChangeToken) { _, _ in
                flashFontSizeHud(displaySettings.fontSizePercent)
            }
        }
        // The window is titled with a transparent, full-size titlebar, so its
        // top safe area is the native titlebar row. The editor draws its own
        // chrome in *window* coordinates — traffic lights float above the title
        // row — therefore the whole container ignores that inset. Without this
        // every band (title row, tab strip, sidebar sheet) shifts down by the
        // titlebar height and the offsets below can never reach the top edge.
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
        // Focus state for the pane pigment. Zero-sized, invisible, inert.
        .background(WindowKeyObserver { key in
            if windowIsKey != key { windowIsKey = key }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false))
        .environment(\.windowIsKey, windowIsKey)
    }
}

// MARK: - Oracle flip card

/// The window's true content — a flip card. Front face = the code editor
/// (chrome and all); reverse face = Pythia alone. `oracleOnly` turns the card
/// over: the editor does not slide or maximize, it *turns away*.
///
/// The editor-glass backdrop is the one layer that must never be 3D-transformed;
/// it therefore lives *behind* the card, static and shared by both faces, while
/// only the content (editor / Pythia) actually turns over.
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
    @State private var toolbarAvailableWidth: CGFloat = 800

    private var toolbarSidebarWidth: CGFloat {
        EditorPanelWidths(available: toolbarAvailableWidth,
                          sidebar: chrome.sidebarVisible ? chrome.sidebarWidth : nil,
                          inspector: chrome.pythiaVisible ? chrome.pythiaWidth : nil).leading
    }

    /// Width of the active surface's leading number column, in window
    /// coordinates. The title starts past it, so it must be the same value the
    /// surface draws — variable with the digit count, and doubled for diffs.
    private var toolbarGutterWidth: CGFloat {
        if let diff = tabs.activeDiffTab {
            return DiffSurface.leadingGutterWidth(for: diff.document)
        }
        if let controller = tabs.activeTab?.controller {
            if controller.imagePreview.isActive { return ImagePreviewSurface.rulerColumnWidth }
            if controller.richDocument.active { return RichTextSurface.rulerColumnWidth }
        }
        guard tabs.activeEntityTab == nil else { return 0 }
        guard EditorDisplaySettings.shared.showLineNumbers else {
            return EditorGutterStyle.markerColumnWidth
        }
        guard let document = tabs.activeDocument else { return 0 }
        return EditorContainerView.makeGutter(
            document: document, theme: chrome.theme,
            lineCount: max(tabs.activeLineCount, document.lineCount)
        ).width
    }

    private var toolbarLayout: EditorToolbarLayout {
        let panels = EditorPanelWidths(available: toolbarAvailableWidth,
            sidebar: chrome.sidebarVisible ? chrome.sidebarWidth : nil,
            inspector: chrome.pythiaVisible ? chrome.pythiaWidth : nil)
        return EditorToolbarLayout(windowWidth: toolbarAvailableWidth,
                                   leadingWidth: panels.leading,
                                   trailingWidth: panels.trailing,
                                   showsPythia: chrome.pythiaVisible || chrome.oracleOnly)
    }

    /// Title-row content for the native toolbar: the file/entity glyph + the
    /// active document's name, cleared past the sidebar + gutter while the
    /// sidebar is open so the filename never sits on the sidebar or the code
    /// column's line numbers.
    private var toolbarTitle: some View {
        HStack(spacing: 6) {
            if toolbarLayout.showsAppTitle {
                Text("ÆtherCodex")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
            }
            if let entity = tabs.activeEntityTab {
                Text(entity.kind.glyph).font(.system(size: 11))
            } else {
                Image(systemName: FileIcon.symbol(for: activeToolbarFileURL))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text(chrome.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: toolbarLayout.titleWidth, alignment: .leading)
        .clipped()
        // Always clear the gutter, open or folded: the number column sits at the
        // window's leading edge in both states and widens with the digits of the
        // largest line number.
        .padding(.leading, toolbarGutterWidth + (chrome.sidebarVisible ? 16 : 8))
    }

    private var activeToolbarFileURL: URL? {
        tabs.activeEntityTab == nil ? tabs.activeTab?.controller.currentFile : nil
    }

    /// The toolbar stays mounted outside the flip, so the return control must
    /// live here (not on the hidden front face) while the window is turned.
    private var oracleReturnButton: some View {
        Button {
            chrome.onToggleOracleOnly?()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Return to Editor")
    }

    /// Bounded companion row in the right-hand native toolbar. Its horizontal
    /// scroll view must not negotiate an unbounded height or crowd the corners.
    private var toolbarCompanionPicker: some View {
        CompanionPicker(model: pythiaModel)
            .environment(\.pythiaPalette, ThemeRegistry.shared.current.pythia)
            .frame(width: toolbarLayout.companionWidth, height: 28)
    }

    /// The three-face Pythia view switch, lifted out of the panel into the native
    /// toolbar so the panel header stops pushing the chat content down. Bound to
    /// the model through a manual binding — the flip card must not observe the
    /// whole chat model or it re-mounts the editor on every turn.
    private var toolbarModePicker: some View {
        PanelModePicker(mode: Binding(
            get: { pythiaModel.mode },
            set: { pythiaModel.mode = $0 }
        ))
        .environment(\.pythiaPalette, ThemeRegistry.shared.current.pythia)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Window base
                // `Material` of the theme's weight, so base and glass both answer
                // to the theme. No `NSVisualEffectView`: the window is opaque
                // (`NativeWindowChrome`), so an AppKit `.withinWindow` material
                // could never sample the desktop — it only frosted the window's
                // own background colour. Material over the theme ground gives the
                // same frost the sidebars speak, and keeps the window from reading
                // as system chrome wherever translucent content lets it through.
                // It stays put while the window's *content* turns over above it
                // and must never be 3D-transformed.
                ZStack {
                    Color(nsColor: chrome.theme.editorBackground)
                    Rectangle().fill(chrome.theme.editorMaterial)
                }
                .ignoresSafeArea()

                // This rotates content only. The native toolbar, frame and
                // window-server shadow are outside this SwiftUI transform.
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
        // The native toolbar owns its controls and scrolling backdrop. Hide
        // only the per-item capsules, not the system's effect-bearing layers.
        .toolbar {
            if chrome.oracleOnly {
                ToolbarItem(placement: .navigation) {
                    oracleReturnButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                // Breadcrumb + the single sliding sidebar toggle. Collapsed the
                // slot is just the toggle (40pt); open it expands to ride the
                // sheet's trailing edge so the button slides beside the
                // breadcrumb at the sidebar's top-right corner.
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 8) {
                        Text(chrome.currentFolder?.lastPathComponent ?? "Kein Ordner")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(chrome.sidebarVisible ? 1 : 0)
                            .frame(maxWidth: chrome.sidebarVisible ? .infinity : 0, alignment: .leading)
                            .clipped()
                            .accessibilityHidden(!chrome.sidebarVisible)
                        SidebarToggleButton(chrome: chrome)
                            .offset(y: chrome.sidebarVisible ? 4 : 0)
                    }
                    .frame(width: chrome.sidebarVisible ? max(32, toolbarSidebarWidth - 112) : 40)
                    .padding(.trailing, chrome.sidebarVisible ? 8 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: chrome.sidebarVisible)
                    .animation(.easeInOut(duration: 0.18), value: toolbarSidebarWidth)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .navigation) {
                    toolbarTitle
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .automatic) {
                    EditorModeControls(tabs: tabs)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            // On macOS primaryAction is leading, not trailing. A native
            // flexible space followed by one automatic item anchors this group
            // at the window's right edge, independent of inspector width/state.
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItem(id: "pythia-window-corner", placement: .automatic) {
                HStack(spacing: 8) {
                    if chrome.pythiaVisible || chrome.oracleOnly {
                        toolbarModePicker
                    }
                    if chrome.pythiaVisible && !chrome.oracleOnly {
                        toolbarCompanionPicker
                    }
                    PythiaCornerControls(chrome: chrome)
                }
                .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // Per-pane safe-area bars own the progressive effect. Suppress only
        // the native toolbar fill through SwiftUI, never its private layers.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Our document title is a real toolbar item. Remove the automatic
        // window/app title through SwiftUI rather than hiding AppKit subviews.
        .toolbar(removing: .title)
        // The toolbar is chrome the *window server* owns; the editor draws its
        // own bands in window coordinates. Without ignoring the toolbar's safe
        // area the whole content (sidebars, tab strip, code view) is pushed down
        // by the toolbar height and the top scroll-edge blur is hidden behind
        // the toolbar band instead of shining through it.
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarAvailableWidth = $0 }
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Only the Pythia tint lives here; the desktop backdrop is shared,
            // static, and lives behind the flip card in `OracleFlipRoot`.
            Color(nsColor: chrome.theme.pythia.background)
                .opacity(ThemeSettings.shared.resolvedSidebarBackgroundOpacity(for: chrome.theme))

            // The way back to the editor now lives in the native toolbar (which
            // stays mounted outside the flip), so this face hosts Pythia alone,
            // its header cleared below the toolbar.
            PythiaPanel(model: pythiaModel)
                .environment(\.markdownThemeName, chrome.theme.name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
    }

}

private struct EditorModeSurface: View {
    let editor: EditorViewController
    let theme: SyntaxTheme
    @ObservedObject var document: EditorDocumentModel
    @ObservedObject var rich: RichTextDocument
    @ObservedObject var imageModel: ImagePreviewModel
    @ObservedObject var htmlModel: HTMLPreviewModel
    /// Observed (not read) so the gutter re-solves when the code font size or
    /// line-number visibility changes — `makeGutter` reads the shared base font,
    /// and this child must re-run its body in the same pass the parent does.
    @ObservedObject private var displaySettings = EditorDisplaySettings.shared
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
            // Spans the window: the image surface owns its leading ruler column
            // (band + glass + fade), so it must not be inset by the sidebar.
            ImagePreviewSurface(model: imageModel, theme: theme,
                                leading: leading, trailing: trailing, topInset: topInset)
        } else if htmlModel.isActive {
            HTMLPreviewSurface(model: htmlModel, theme: theme, topInset: topInset, onShowSource: editor.showHTMLSource)
                .padding(.leading, leading).padding(.trailing, trailing)
        } else if rich.active {
            RichTextSurface(document: rich, theme: theme,
                            leading: leading, trailing: trailing, topInset: topInset)
        } else {
            codeSurface
        }
    }

    private var codeSurface: some View {
        TextKit2ScrollSurface(attributedString: document.attributedString,
                                   backgroundColor: theme.editorBackgroundColor,
                                   gutter: EditorContainerView.makeGutter(document: document, theme: theme),
                                   leadingChromeWidth: leading, trailingChromeWidth: trailing,
                                   topChromeInset: topInset,
                                   gutterBackgroundOpacity: ThemeSettings.shared.resolvedRulerBackgroundOpacity(for: theme),
                                   sharedTextStorage: editor.textStorage, existingEditor: editor.textView,
                                   searchModel: editor.quickSearch,
                                   findReplace: editor.findReplace,
                                   showWrapColumn: showWrapColumn,
                                   wrapColumn: wrapColumn,
                                   lineCount: document.lineCount, maxLineWidth: document.maxLineWidth,
                                   wordWrap: document.wordWrap, revision: document.revision)
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


/// The Pythia pair is the last content in the native trailing toolbar group.
private struct PythiaCornerControls: View {
    @ObservedObject var chrome: EditorChromeState

    private enum Metric {
        static let glyph: CGFloat = 26
        static let height: CGFloat = 24
        static let pad: CGFloat = 2
        static let gap: CGFloat = 8
    }

    var body: some View {
        Group {
            HStack(spacing: Metric.gap) {
                cornerButton(chrome.oracleOnly ? "arrow.uturn.backward" : "arrow.up.left.and.arrow.down.right",
                             accent: .secondary,
                             help: chrome.oracleOnly ? "Return to Editor" : "Transform window into Pythia") {
                    chrome.onToggleOracleOnly?()
                }
                if chrome.pythiaVisible && !chrome.oracleOnly {
                    cornerButton("sidebar.right",
                                 accent: chrome.theme.pythia.accentColor,
                                 help: "Close Pythia sidebar") {
                        chrome.onTogglePythia?()
                    }
                } else {
                    cornerButton("rectangle.righthalf.inset.filled",
                                 accent: chrome.theme.pythia.accentColor,
                                 help: "Open Pythia") {
                        if chrome.oracleOnly { chrome.onToggleOracleOnly?() }
                        if !chrome.pythiaVisible { chrome.onTogglePythia?() }
                    }
                }
            }
        }
    }

    /// Shared capsule-styled icon button for the window corner.
    private func cornerButton(_ system: String,
                              accent: Color,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Metric.glyph, height: Metric.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .help(help)
        .padding(Metric.pad)
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
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: chrome.theme.sidebarAccent))
        .accessibilityLabel("Toggle Sidebar")
        .help("Toggle Sidebar")
    }
}