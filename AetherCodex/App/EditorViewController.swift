import Cocoa
import CSafeLayout

// MARK: - HermeticTextView

/// NSTextView subclass that wraps draw(_:) in SafeCallBlock to prevent
/// SIGILL crashes from AppKit private layout methods when the glyph tree
/// is transiently inconsistent after text storage mutations.
private final class HermeticTextView: NSTextView {
    /// Weak back-pointer so ⌥-drag column selection and ⌥-click multi-caret can
    /// be routed into `EditorViewController` (which owns the layout helpers).
    weak var multiCaretOwner: EditorViewController?

    private var optionDragActive = false
    private var optionDragBegan = false
    private var optionDragAnchor: NSPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        if !SafeCallBlock({ super.draw(dirtyRect) }) {
            backgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    // ── ⌥ (Option) mouse: click = add caret, drag = column (box) selection ──

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            optionDragActive = true
            optionDragBegan = false
            optionDragAnchor = convert(event.locationInWindow, from: nil)
            multiCaretOwner?.beginOptionMouse(at: optionDragAnchor)
            return
        }
        optionDragActive = false
        multiCaretOwner?.resetColumnSelectionIfNeeded()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if optionDragActive {
            let p = convert(event.locationInWindow, from: nil)
            if !optionDragBegan {
                let d = hypot(p.x - optionDragAnchor.x, p.y - optionDragAnchor.y)
                if d > 3 { optionDragBegan = true }
            }
            if optionDragBegan {
                multiCaretOwner?.dragColumnSelection(to: p)
            }
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if optionDragActive {
            optionDragActive = false
            if optionDragBegan {
                multiCaretOwner?.endColumnSelection(at: convert(event.locationInWindow, from: nil))
            } else {
                multiCaretOwner?.toggleCaret(at: optionDragAnchor)
            }
            return
        }
        super.mouseUp(with: event)
    }
}

extension Notification.Name {
    /// Posted when the titlebar chrome (mask + traffic lights) becomes visible or hidden.
    static let editorTitlebarVisibilityDidChange = Notification.Name("editorTitlebarVisibilityDidChange")

    /// Posted when a memory card's file link is tapped — opens the file in the editor.
    static let openFileInEditor = Notification.Name("openFileInEditor")
}

/// Glass-effect drag handle for the titlebar zone.
/// - Drag: moves the window
/// - Double-click: inline rename
/// - Right-click / Ctrl-click: dropdown menu (Go to File, Show in Finder, Copy Path)
private final class TitlebarDragHandle: NSView {
    var onDoubleClick: (() -> Void)?
    var onShowDropdown: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if event.modifierFlags.contains(.control) || event.buttonNumber == 1 {
            onShowDropdown?(event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onShowDropdown?(event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Associated-object keys for re-entrancy guards.
private enum Reentrancy {
    static var highlightKey: UInt8 = 0
    static var cursorEditKey: UInt8 = 0
}

class EditorViewController: NSViewController {
    var textView: NSTextView!
    var scrollView: NSScrollView!
    var currentFile: URL?
    var isDirty = false
    var sidebarVisible = false
    let richDocument = RichTextDocument()
    let imagePreview = ImagePreviewModel()
    let htmlPreview = HTMLPreviewModel()

    /// File URL whose source is currently resident in the text view (HTML mode).
    /// Lets source→preview→source round-trips preserve unsaved edits.
    private var htmlSourceLoadedFor: URL?

    var supportsRichText: Bool {
        ["md", "markdown", "mdown", "rtf"].contains(currentFile?.pathExtension.lowercased() ?? "")
    }

    var supportsHTML: Bool {
        HTMLFileType.isHTML(currentFile ?? URL(fileURLWithPath: "/"))
    }

    func showRichText() {
        guard supportsRichText, currentFile?.pathExtension.lowercased() != "rtf" else { return }
        do {
            try richDocument.load(Data(textView.string.utf8), markdown: true)
            currentLanguageName = "Markdown · Text"
            updateTitle()
        } catch { NSApp.presentError(error) }
    }

    func showMarkdownSource() {
        guard richDocument.markdown else { return }
        do {
            let data = try richDocument.encoded()
            suppressTextDidChange = true
            textView.string = String(decoding: data, as: UTF8.self)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            suppressTextDidChange = false
            SyntaxOracle.shared.setLanguage(forExtension: "md")
            currentLanguageName = "Markdown"
            richDocument.active = false
            rehighlight()
            updateTitle()
        } catch { NSApp.presentError(error) }
    }

    // MARK: - Overlay Panel Widths

    /// Width of the floating sidebar overlay (0 = hidden). Used for
    /// text-container width when word wrap is on so text wraps before the
    /// overlay edge. When word wrap is off, text scrolls under the glass
    /// panel and the native NSVisualEffectView blur engages.
    var sidebarOverlayWidth: CGFloat = 0 {
        didSet { updateOverlayInsets() }
    }

    /// Width of the floating Pythia overlay (0 = hidden).
    var pythiaOverlayWidth: CGFloat = 0 {
        didSet { updateOverlayInsets() }
    }

    // MARK: - Current Line Highlight
    // (highlight state stored on HighlightingLayoutManager)
    // MARK: - Language

    /// Human-readable language name for the current file (e.g. "Swift", "Ruby", "Markdown").
    var currentLanguageName: String = "Plain Text"

    // MARK: - Status Bar Callback

    /// Set by MainWindowController — called on every cursor move / file change.
    /// Params: (lineCol, tabInfo, languageName, isDirty)
    var onStatusChange: ((String, String, String, Bool) -> Void)?

    /// Set by MainWindowController — called when the document title changes,
    /// so the toolbar title item can mirror the window title.
    var onTitleChange: ((String) -> Void)?

    /// Set by MainWindowController — called with a highlighted snapshot of the
    /// document whenever it changes, feeding the SwiftUI TextKit 2 surface.
    var onDocumentChange: ((NSAttributedString) -> Void)?

    /// Set by MainWindowController — called with cheap (lineCount, maxLineWidth)
    /// on every edit. Lets the SwiftUI surface size its scroll content without a
    /// full attributed-string copy + layout on each keystroke.
    var onDocumentMetricsChange: ((Int, Int) -> Void)?

    // MARK: - Hermetic Text Pipeline

    private var layoutManager: HighlightingLayoutManager?
    private(set) var textStorage: NSTextStorage!
    private var settingsObserver: NSObjectProtocol?
    private var themeObserver:    NSObjectProtocol?
    /// Token for the scroll-view bounds observer. Block-based observers are *not*
    /// auto-unregistered, so the token must be held to be removed in `deinit` —
    /// otherwise every closed tab leaves a live block inside NotificationCenter.
    private var scrollBoundsObserver: NSObjectProtocol?

    // MARK: - Per-Window Word Wrap Override

    /// When non-nil, overrides the `.aether-properties` `softWrap` setting for this
    /// editor instance. Set by the View → Word Wrap menu toggle. `nil` means
    /// "defer to `.aether-properties` config".
    var wordWrapOverride: Bool? = nil

    // MARK: - Folding

    let foldState = FoldState()
    private var foldRegions: [FoldRegion] = []
    private var foldDetectionDebounce: Timer?
    /// Suppress textDidChange during programmatic loads (openFile/newDocument).
    private var suppressTextDidChange = false

    /// ZIEL A — Flash-AI-Neufenser. Generation counter + task handle guard
    /// against stale conjurations landing in a newer document.
    private var flashGeneration = 0
    private var flashTask: Task<Void, Never>?
    /// Guard against re-entrant paste handling — prevents infinite recursion
    /// when `insertText` triggers another `shouldChangeTextIn` cycle.
    private var isHandlingPaste = false

    /// Debounced re-highlight when scrolling brings new text into viewport.
    private var scrollHighlightTimer: Timer?

    // MARK: - Incremental Edit Pipeline (keystroke path)

    /// Debounced full-document re-highlight — converges colors after the typing
    /// pause; cancelled and re-armed on every keystroke.
    private var highlightDebounce: Timer?
    /// Edit context captured in `shouldChangeTextIn` (old text still live) and
    /// consumed in `textDidChange` (new text already committed).
    private var pendingEditRange = NSRange(location: NSNotFound, length: 0)
    private var pendingReplacementText: NSString?
    private var pendingReplacedText: NSString?
    /// UTF-16 offsets of every line start, in document order. Maintained
    /// incrementally (rebuilt only when the edit contains/removes a newline),
    /// serving O(log n) line-index lookups for metrics and the highlight range.
    private var lineStarts: [Int] = [0]
    /// Incremental document metrics: line count, widest line (UTF-16 units) and
    /// its 0-based index — kept exact across every edit without O(n) rescans.
    private var cachedLineCount = 1
    private var cachedMaxLineWidth = 0
    private var cachedMaxLineIndex = 0

    // MARK: - Large File Handling

    /// Files larger than this (bytes) use viewport-only highlighting with background parse.
    private static let largeFileThreshold = 1_000_000 // 1 MB

    /// Whether the currently open file exceeds the large-file threshold.
    private var isLargeFile = false

    /// Background parse work item — cancelled on new file open or close.
    private var backgroundParseWork: DispatchWorkItem?

    /// Fraction complete (0.0…1.0) for the background full-document parse.
    private(set) var backgroundParseProgress: Double = 0.0 {
        didSet {
            if let cb = onBackgroundParseProgress { cb(backgroundParseProgress) }
        }
    }

    /// Callback to status bar for showing parse progress.
    var onBackgroundParseProgress: ((Double) -> Void)?
    private var dragHandle: TitlebarDragHandle?

    /// Standalone line-number gutter — fixed position, text scrolls behind it.
    private var lineNumberGutter: LineNumberRulerView?
    /// Blur backdrop behind the line-number gutter — text scrolling behind it blurs natively.
    private var gutterBlurView: NSVisualEffectView?
    private var _lastGutterWidth: CGFloat?
    private var _lastGutterChangeTime: CFTimeInterval = 0

    /// Total width from sidebar right edge to first character of text:
    /// gutter width (the text container sits flush — inset 0).
    var effectiveGutterWidth: CGFloat {
        (lineNumberGutter?.gutterWidth ?? 52)
    }

    // MARK: - Incremental Search (Ctrl+S)

    /// SwiftUI-owned quicksearch — the single source of truth, observed by
    /// `TextKit2ScrollSurface`. The editor has no AppKit search bar.
    let quickSearch = QuickSearchModel()
    /// TextMate-style find & replace state (⌘F / ⌘⌥F / ⌘G / ⌘E).
    let findReplace = FindReplaceModel()

    // MARK: - Proximity Titlebar (mouse-move monitor — mask + traffic lights)

    /// Polling timer for mouse position — checks every 0.25s.
    private var proximityTimer: Timer?
    /// Timer that auto-hides titlebar after mouse leaves reveal zone.
    private var autoHideTimer: Timer?
    /// Distance from top of window that triggers titlebar reveal.
    private let titlebarRevealZone: CGFloat = 120
    /// Delay before auto-hiding after mouse leaves zone.
    private let titlebarAutoHideDelay: TimeInterval = 2.5
    /// Cooldown after scroll/type dismissal — prevents flicker.
    private var proximityCooldownUntil: Date = .distantPast
    /// Whether titlebar chrome (traffic lights) is currently visible.
    /// Read by MainWindowController via editorTitlebarVisibilityDidChange notification.
    internal var titlebarVisible = true
    /// Guards dismissTitlebar/hideTitlebar until viewDidAppear completes.
    private var hasAppeared = false
    
    /// Inline rename text field (shown on double-click in titlebar).
    private var renameField: NSTextField?

    // MARK: - Multiple Selections / Column (Box) Selection

    /// Guard so our own `selectedRanges` writes don't trip `selectionDidChange`
    /// into resetting the ⌘D occurrence state or column-drag bookkeeping.
    private var isApplyingMultiSelection = false

    /// ⌘D "Select Next Occurrence" — the literal being matched, and the char
    /// index right after the most recently added match (search cursor).
    private var occurrenceSearchString: String?

    /// ⌥-drag column selection anchor (layout-manager coordinate space):
    /// line content start of the mouse-down line, and its caret x-offset.
    private var columnAnchorLineStart: Int = 0
    private var columnAnchorX: CGFloat = 0
    private var columnSelectionActive = false

    // MARK: - Lifecycle

    override func loadView() {
        // NSScrollView is the direct view — required for the split-item
        // scroll-edge accessory to discover it (proven in ScrollEdgeTestbed:
        // intermediate wrapper views block the compositor).
        let sv = NSScrollView(frame: .zero)
        sv.autoresizingMask = [.width, .height]
        sv.translatesAutoresizingMaskIntoConstraints = true
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.borderType = .noBorder
        // Disable auto content insets so content reaches y=0 (under toolbar).
        // The unified toolbar + safeAreaBar signal the compositor to apply
        // progressive blur where content crosses the bar boundary.
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        sv.contentView.drawsBackground = false
        sv.contentView.backgroundColor = .clear
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        scrollView = sv
        view = sv
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupEditor()
        richDocument.onChange = { [weak self] in
            self?.isDirty = true
            self?.updateTitle()
        }
        quickSearch.textView = textView
        findReplace.textView = textView
        applyThemeChrome()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: ThemeSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyThemeChrome()
            self?.rehighlight()
        }


        applyWordWrap()

        // Current-line highlight: track selection changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )

        // Direct callback — fires on every ThemeRegistry.current change
        ThemeRegistry.shared.observeChanges(target: self) { [weak self] in
            self?.applyThemeChrome()
            self?.rehighlight()
        }
    }

    private func rehighlight() {
        defer { notifyDocumentChange() }
        guard let storage = textStorage, storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        SyntaxOracle.shared.applyHighlighting(to: storage, range: fullRange, font: nil)
    }

    // MARK: - Scope Inspector (Ctrl+Shift+P)

    private func showScopeInspector() {
        guard let tv = textView, let storage = textStorage else { return }
        let text = storage.string
        let sel = tv.selectedRange()
        let pos = sel.location
        guard pos < (text as NSString).length else { return }

        let tokens = SyntaxOracle.shared.tokensAt(position: pos, in: text)
        let theme = ThemeRegistry.shared.current

        let lines: [String] = tokens.map { token in
            let style = theme.style(for: token.scope)
            let loc = token.range.location
            let len = min(token.range.length, 50)
            let snippet = ((text as NSString).substring(with: NSRange(location: loc, length: len)))
                .replacingOccurrences(of: "\n", with: "↵")
            let boldStr = style.isBold == true ? "B" : "·"
            let italicStr = style.isItalic == true ? "I" : "·"
            let strikeStr = style.isStrikethrough == true ? "S" : "·"
            let underlineStr = style.isUnderline == true ? "U" : "·"
            let sizeStr: String
            if let sz = style.fontSize {
                sizeStr = sz < 10 ? "×\(sz)" : "\(Int(sz))pt"
            } else { sizeStr = "—" }
            let fg = style.foreground ?? ThemeRegistry.shared.current.editorForeground
            let hex = fg.usingColorSpace(.deviceRGB) ?? fg
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            hex.getRed(&r, green: &g, blue: &b, alpha: nil)
            let colorStr = String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
            return "\(token.scope.rawValue) [\(loc)..\(loc+token.range.length)] \(snippet) |\(boldStr)\(italicStr)\(strikeStr)\(underlineStr)| \(sizeStr) \(colorStr)"
        }

        var tip: String
        if tokens.isEmpty {
            tip = "⚠️ No tokens at position \(pos) — tree-sitter and heuristic returned nothing"
        } else {
            tip = "🎯 Position \(pos) — \(tokens.count) token(s):\n\n" + lines.joined(separator: "\n")
        }

        // Show as a floating tooltip near the cursor
        let tooltip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        tooltip.isOpaque = false
        tooltip.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        tooltip.level = .floating
        tooltip.hasShadow = true
        tooltip.isReleasedWhenClosed = false

        let tf = NSTextField(frame: NSRect(x: 10, y: 10, width: 500, height: 100))
        tf.isEditable = false
        tf.isSelectable = true
        tf.isBordered = false
        tf.drawsBackground = false
        tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.stringValue = tip
        tf.lineBreakMode = .byWordWrapping
        tf.usesSingleLineMode = false
        tf.maximumNumberOfLines = 0
        tooltip.contentView?.addSubview(tf)

        // Position near cursor
        let cursorRect = tv.firstRect(forCharacterRange: NSRange(location: pos, length: 0), actualRange: nil)
        let screenRect = tv.window?.convertToScreen(cursorRect) ?? cursorRect
        let tipX = min(screenRect.origin.x + 8, NSScreen.main?.frame.maxX ?? 1920 - 520)
        let tipY = screenRect.origin.y - 120 - 8
        tooltip.setFrame(NSRect(x: tipX, y: tipY, width: 520, height: 120), display: false)
        tooltip.orderFront(nil)

        // Dismiss on any key or click
        self.scopeInspectorPanel?.close()
        self.scopeInspectorPanel = tooltip
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.scopeInspectorPanel?.close()
            self?.scopeInspectorPanel = nil
        }

        // Dismiss on next key press
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.scopeInspectorPanel?.close()
            self?.scopeInspectorPanel = nil
            return event
        }
    }

    private var scopeInspectorPanel: NSPanel?

    // MARK: - Safe Area Bars (safeAreaBar equivalent)

    /// Updates contentInsets and safe-area-bar zones for gutter, sidebar, and Pythia.
    ///
    /// This is the AppKit equivalent of SwiftUI's:
    ///   .safeAreaBar(edge: .leading)  { /* gutter + sidebar */ }
    ///   .safeAreaBar(edge: .trailing) { /* pythia */ }
    ///
    /// `additionalSafeAreaInsets` communicates bar positions to the layout system
    /// (and potentially the compositor). `contentInsets` are managed manually:
    /// only the gutter pushes text right; sidebar/pythia allow text to flow under
    /// the glass, where NSVisualEffectView provides the blur.
    private func updateOverlayInsets() {
        guard let sv = scrollView else { return }

        let gutterW = lineNumberGutter?.gutterWidth ?? 52

        // Content insets: gutter only. Text scrolls behind sidebar/pythia glass.
        // Equality-guarded: assigning insets unconditionally re-invalidates layout,
        // producing an infinite viewDidLayout → setNeedsLayout loop.
        let targetInsets = NSEdgeInsets(
            top: sv.contentInsets.top,
            left: gutterW,
            bottom: sv.contentInsets.bottom,
            right: 0
        )
        if !Self.insetsEqual(sv.contentInsets, targetInsets) {
            sv.contentInsets = targetInsets
        }

        // Safe area bars: tell the layout system where the bars live.
        // Top is handled by NSSplitViewItemAccessoryViewController (native compositor blur).
        // Leading = gutter + sidebar overlay; Trailing = pythia overlay.
        let targetSafe = NSEdgeInsets(
            top: 0,
            left: gutterW + sidebarOverlayWidth,
            bottom: 0,
            right: pythiaOverlayWidth
        )
        if !Self.insetsEqual(sv.additionalSafeAreaInsets, targetSafe) {
            sv.additionalSafeAreaInsets = targetSafe
        }
    }

    private static func insetsEqual(_ a: NSEdgeInsets, _ b: NSEdgeInsets) -> Bool {
        a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right
    }

    private var hasLaidOut = false
    override func viewDidLayout() {
        super.viewDidLayout()

        let gutterW = lineNumberGutter?.gutterWidth ?? 24
        let oldOffset = scrollView.contentView.bounds.origin

        // Delegate to updateOverlayInsets for contentInsets + safeAreaBar zones.
        updateOverlayInsets()

        // Preserve scroll offset if left inset changed.
        if abs(scrollView.contentInsets.left - gutterW) > 0.5 {
            scrollView.contentView.scroll(to: oldOffset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Gutter blur backdrop and ruler at x=0 within the contentInset gutter zone.
        // Sidebar glass overlays them when visible; text starts at gutterW.
        // Equality-guarded so we don't re-invalidate layout on every pass.
        let gutterFrame = NSRect(x: 0, y: 0, width: gutterW,
                                  height: scrollView.bounds.height)
        if gutterBlurView?.frame != gutterFrame { gutterBlurView?.frame = gutterFrame }
        if lineNumberGutter?.frame != gutterFrame { lineNumberGutter?.frame = gutterFrame }

        // Reflow text on window resize when word wrap is enabled.
        if effectiveWordWrap, let tv = textView, let tc = tv.textContainer,
           let lm = layoutManager, let ts = textStorage {
            if abs(tv.frame.width - tc.containerSize.width) > 0.5 {
                tc.containerSize = NSSize(width: tv.frame.width,
                                          height: CGFloat.greatestFiniteMagnitude)
                let fullRange = NSRange(location: 0, length: ts.length)
                lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            }
        }
        guard !hasLaidOut, view.frame.width > 0, view.frame.height > 0 else { return }
        hasLaidOut = true
        newDocument()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startProximityTimer()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        startProximityTimer()
        resetAutoHideTimer()
    }

    private func startProximityTimer() {
        guard proximityTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollMousePosition()
        }
        RunLoop.current.add(timer, forMode: .common)
        proximityTimer = timer
    }

    private func stopProximity() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    /// Polls NSEvent.mouseLocation and triggers show/hide based on window-relative position.
    private func pollMousePosition() {
        // Use textView?.window — resilient even if editor VC's view was reparented.
        guard let win = textView?.window ?? view.window,
              Date() > proximityCooldownUntil else { return }
        let point = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inZone = point.y > win.frame.height - titlebarRevealZone
        if inZone {
            if !titlebarVisible { showTitlebar() }
            resetAutoHideTimer()
        }
    }

    private func resetAutoHideTimer() {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: titlebarAutoHideDelay, repeats: false) { [weak self] _ in
            self?.autoHideCheck()
        }
    }

    /// Only hide if mouse has actually left the reveal zone.
    /// Never hide traffic lights when sidebar/filebrowser is open.
    /// Guarded by hasAppeared — prevents premature hide at startup.
    private func autoHideCheck() {
        guard hasAppeared, let win = view.window else { return }
        let point = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inZone = point.y > win.frame.height - titlebarRevealZone
        if !inZone {
            hideTitlebar(hideTrafficLights: !sidebarVisible)
        }
    }

    /// Hides mask + traffic lights with cooldown — called on scroll/type events.
    /// Only hides if mouse has actually left the titlebar zone.
    /// Guarded by hasAppeared — prevents premature hide during initial layout.
    func dismissTitlebar() {
        guard hasAppeared else { return }
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        proximityCooldownUntil = Date().addingTimeInterval(0.5)
        hideTitlebar(hideTrafficLights: !sidebarVisible)
    }

    private func showTitlebar() {
        guard !titlebarVisible else { return }
        titlebarVisible = true
        NotificationCenter.default.post(name: .editorTitlebarVisibilityDidChange, object: self)
        // Fade in traffic lights
        if let tlView = view.window?.standardWindowButton(.closeButton)?.superview {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                tlView.animator().alphaValue = 1.0
            }
        }
    }

    private func hideTitlebar(hideTrafficLights: Bool = true) {
        guard titlebarVisible else { return }
        titlebarVisible = false
        NotificationCenter.default.post(name: .editorTitlebarVisibilityDidChange, object: self)
        if hideTrafficLights, let tlView = view.window?.standardWindowButton(.closeButton)?.superview {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                tlView.animator().alphaValue = 0.0
            }
        }
    }
        // MARK: - Title Dropdown

    /// Show a dropdown menu with file-related actions (Go to File, Show in Finder, Copy Path).
    func showTitleDropdown(at event: NSEvent) {
        let menu = NSMenu(title: "File Actions")

        let goToFileItem = NSMenuItem(title: "Go to File…", action: #selector(goToFileFromMenu(_:)), keyEquivalent: "t")
        goToFileItem.keyEquivalentModifierMask = .command
        menu.addItem(goToFileItem)

        if let file = currentFile {
            menu.addItem(.separator())
            let showItem = NSMenuItem(title: "Show in Finder", action: #selector(showInFinderFromMenu(_:)), keyEquivalent: "")
            showItem.representedObject = file
            menu.addItem(showItem)

            let copyItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathFromMenu(_:)), keyEquivalent: "")
            copyItem.representedObject = file
            menu.addItem(copyItem)

            let renameItem = NSMenuItem(title: "Rename", action: #selector(renameFromMenu(_:)), keyEquivalent: "\r")
            renameItem.keyEquivalentModifierMask = []
            renameItem.representedObject = file
            menu.addItem(renameItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func goToFileFromMenu(_ sender: Any?) {
        // Forward via responder chain to MainWindowController
        NSApp.sendAction(#selector(MainWindowController.goToFile(_:)), to: nil, from: sender)
    }

    @objc private func showInFinderFromMenu(_ sender: Any?) {
        guard let file = (sender as? NSMenuItem)?.representedObject as? URL ?? currentFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    @objc private func copyPathFromMenu(_ sender: Any?) {
        guard let file = (sender as? NSMenuItem)?.representedObject as? URL ?? currentFile else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    @objc private func renameFromMenu(_ sender: Any?) {
        startRename()
    }

    // MARK: - Inline Rename
    
    /// Show an inline rename field at the titlebar position.
    func startRename() {
        guard let win = view.window, let file = currentFile else { return }
        guard renameField == nil else { return }  // already editing
        
        let name = file.lastPathComponent
        let tf = NSTextField(frame: .zero)
        tf.stringValue = name
        tf.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        tf.textColor = .labelColor
        tf.backgroundColor = .controlBackgroundColor
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.drawsBackground = true
        tf.isEditable = true
        tf.isSelectable = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.delegate = self
        tf.target = self
        tf.action = #selector(renameFieldAction(_:))
        
        view.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tf.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            tf.widthAnchor.constraint(equalToConstant: 200),
            tf.heightAnchor.constraint(equalToConstant: 22),
        ])
        
        renameField = tf
        win.makeFirstResponder(tf)
        tf.selectText(nil)
    }
    
    @objc private func renameFieldAction(_ sender: NSTextField) {
        commitRename(sender.stringValue)
    }
    
    private func commitRename(_ newName: String) {
        defer { dismissRenameField() }
        guard let file = currentFile, !newName.isEmpty,
              newName != file.lastPathComponent else { return }
        let newURL = file.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: file, to: newURL)
            currentFile = newURL
            isDirty = false
            updateTitle()
        } catch {
            print("Rename failed: \(error)")
            NSSound.beep()
        }
    }
    
    private func dismissRenameField() {
        renameField?.removeFromSuperview()
        renameField = nil
    }

    deinit {
        backgroundParseWork?.cancel()
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = themeObserver    { NotificationCenter.default.removeObserver(o) }
        if let o = scrollBoundsObserver { NotificationCenter.default.removeObserver(o) }
        foldDetectionDebounce?.invalidate()
        scrollHighlightTimer?.invalidate()
        // Titlebar auto-hide disabled — see bounds observer.
        // proximityTimer?.invalidate()
        // autoHideTimer?.invalidate()
        renameField?.removeFromSuperview()
    }

    // MARK: - Editor Setup

    private func setupEditor() {
        // NSTextView → swap NSLayoutManager for HighlightingLayoutManager.
        let initialWidth = max(view.bounds.width, 800)
        textView = HermeticTextView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: 0))
        (textView as? HermeticTextView)?.multiCaretOwner = self

        guard let ts = textView.textStorage else {
            fatalError("NSTextView.textStorage is nil — text system broken")
        }
        self.textStorage = ts

        guard let tc = textView.textContainer else {
            fatalError("NSTextView.textContainer is nil")
        }

        let oldLMs = ts.layoutManagers
        for old in oldLMs {
            old.removeTextContainer(at: old.textContainers.firstIndex(of: tc) ?? 0)
        }
        for old in oldLMs {
            ts.removeLayoutManager(old)
        }

        let ourLM = HighlightingLayoutManager()
        self.layoutManager = ourLM
        ts.addLayoutManager(ourLM)

        ourLM.addTextContainer(tc)
        tc.widthTracksTextView = true
        tc.heightTracksTextView = false
        tc.lineFragmentPadding = 0  // explicit: no hidden left padding in container
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: EditorChromeMetrics.codeLeadingPadding, height: 28)
        textView.delegate = self

        // Disable macOS smart quotes/dashes — code editor, not word processor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Ctrl+Shift+P → scope inspector; Ctrl+S → search; Shift+Ctrl+S → prev
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.textView.window?.isKeyWindow == true else { return event }

            // ── Auto-recover focus: if window is key but text view lost responder
            //     (e.g., user clicked glass titlebar or dismissed search), restore it.
            if !self.quickSearch.isVisible,
               let fr = self.textView.window?.firstResponder,
               fr !== self.textView,
               !(fr is NSText) {
                self.textView.window?.makeFirstResponder(self.textView)
            }

            let rawFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let char = event.charactersIgnoringModifiers?.lowercased()

            // ── Ctrl+S → toggle search / navigate next ──
            if rawFlags == .control, char == "s" {
                self.toggleIncrementalSearch()
                return nil
            }

            // ── Shift+Ctrl+S → navigate previous (when search visible) ──
            if rawFlags == [.control, .shift], char == "s",
               self.quickSearch.isVisible {
                self.searchNavigateBackward()
                return nil
            }

            // ── Esc while search bar visible ──
            if self.quickSearch.isVisible,
               event.keyCode == 53 {
                self.quickSearch.cancel()
                return nil
            }

            // ── Esc collapses multiple selections to the primary caret ──
            if event.keyCode == 53,
               self.textView.selectedRanges.count > 1 {
                self.collapseMultipleSelections()
                return nil
            }

            // ── Ctrl+Shift+P → scope inspector (text view only) ──
            if rawFlags == [.control, .shift], char == "p",
               self.textView.window?.firstResponder == self.textView {
                self.showScopeInspector()
                return nil
            }
            return event
        }

        scrollView.documentView = textView

        // We manage insets manually — safeAreaBar zones defined via
        // additionalSafeAreaInsets on the scrollView. The top-bar blur
        // is handled by NSSplitViewItemAccessoryViewController in
        // MainWindowController, not by auto content insets.
        scrollView.automaticallyAdjustsContentInsets = false

        // Standalone line-number gutter — fixed, text scrolls behind it
        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        ruler.foldState = foldState
        ruler.onFoldToggle = { [weak self] region in
            self?.toggleFold(region)
        }
        ruler.onWidthChanged = { [weak self, weak ruler] in
            guard let self, let ruler else { return }
            let newWidth = ruler.gutterWidth
            let now = CACurrentMediaTime()
            if let last = self._lastGutterWidth, abs(last - newWidth) < 0.5 { return }
            // Aggressive debounce: skip if called more than once per 0.5s
            if now - self._lastGutterChangeTime < 0.5 { return }
            self._lastGutterWidth = newWidth
            self._lastGutterChangeTime = now
            self.view.needsLayout = true
        }
        lineNumberGutter = ruler

        // Blur backdrop behind the gutter — text scrolling under it blurs.
        // Uses .fullScreenUI for the modern glass material (.withinWindow so it
        // reads through only the window content, not the desktop).
        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerCurve = .continuous
        gutterBlurView = blur
        // Sits behind the ruler, so line numbers float on top of the blur.
        scrollView.addSubview(blur)
        scrollView.addSubview(ruler)

        scrollView.tile()

        // Glyph padding is inside NSTextView. The layout manager extends
        // selection and current-line backgrounds through it to the gutter.
        // Top inset pushes first line below the unified toolbar (~52pt).
        textView.textContainerInset = NSSize(width: EditorChromeMetrics.codeLeadingPadding, height: 52)

        // Re-highlight newly visible text on scroll.
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Titlebar auto-hide disabled until scroll-edge is stable.

            // Debounced re-highlight: 150ms pause after scroll stops.
            self.scrollHighlightTimer?.invalidate()
            self.scrollHighlightTimer = Timer.scheduledTimer(withTimeInterval: 0.15,
                                                               repeats: false) { [weak self] _ in
                guard let self else { return }
                let layout = self.textView.layoutManager!
                let tc = self.textView.textContainer!
                let visibleRect = self.scrollView.contentView.bounds
                let visibleGlyphRange = layout.glyphRange(forBoundingRect: visibleRect, in: tc)
                let visibleCharRange = layout.characterRange(forGlyphRange: visibleGlyphRange,
                                                               actualGlyphRange: nil)
                let buf = 2000
                let loc = max(0, visibleCharRange.location - buf)
                let end = min(self.textStorage.length,
                               visibleCharRange.location + visibleCharRange.length + buf)
                if end > loc {
                    SyntaxOracle.shared.applyHighlighting(to: self.textStorage,
                                                           range: NSRange(location: loc, length: end - loc),
                                                           font: nil)
                }
            }
        }

        // Titlebar proximity timer disabled until scroll-edge is stable.
        // startProximityTimer()
    }
    /// Effective word wrap
    /// (`softWrap` key), then falls back to the global user toggle.
    var effectiveWordWrap: Bool {
        // 1. Per-window runtime toggle (View → Word Wrap menu)
        if let ov = wordWrapOverride { return ov }
        // 2. .aether-properties `softWrap` key (per-scope, per-project config)
        if let file = currentFile,
           let scope = TreeSitterScopeMapper.scope(forExtension: file.pathExtension),
           let scopedWrap = ScopeSettings.shared.resolveSoftWrap(scope: scope) {
            return scopedWrap
        }
        // 3. Default: wrap ON
        return true
    }

    /// Apply the user's word wrap preference. When word wrap is ON, text wraps
    /// at editor width. When OFF, horizontal scroll is enabled.
    func applyWordWrap() {
        let wrap = effectiveWordWrap
        guard let tv = textView, let tc = tv.textContainer,
              let clipView = tv.enclosingScrollView?.contentView else { return }
        let oldWidth = tc.containerSize.width
        if wrap {
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]
            tc.widthTracksTextView = true
            scrollView?.hasHorizontalScroller = false
            // Always snap textView width to clip bounds when wrapping —
            // otherwise text stays at old unwrapped width until next resize.
            tv.frame.size.width = clipView.bounds.width
            // widthTracksTextView=true keeps containerSize.width == tv.frame.width,
            // but we force height to infinite so all lines are visible immediately.
            tc.containerSize = NSSize(width: tv.frame.width,
                                      height: CGFloat.greatestFiniteMagnitude)
        } else {
            // Let textView grow past clip bounds for horizontal scroll.
            tv.autoresizingMask = []
            tv.isHorizontallyResizable = true
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tc.widthTracksTextView = false
            // Set container width: never collapse below clip or old value
            let minW = max(clipView.bounds.width, max(oldWidth, 800))
            tc.containerSize = NSSize(width: minW, height: tc.containerSize.height)
            scrollView?.hasHorizontalScroller = true
        }
        // Invalidate layout so glyphs reflow at new container width.
        // Without this, the layout manager keeps cached line fragments
        // at the old width — text only reflows on next window resize.
        if let lm = layoutManager, let ts = textStorage {
            let fullRange = NSRange(location: 0, length: ts.length)
            lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        }
    }

    // MARK: - Folding

    private func detectFolds() {
        guard textStorage.length > 0 else {
            foldRegions = []
            updateRulerFolds()
            return
        }
        foldRegions = FoldDetector.detect(in: textStorage.string)
        updateRulerFolds()
    }

    private func updateRulerFolds() {
        guard let ruler = lineNumberGutter else { return }
        ruler.foldRegions = foldRegions
        ruler.needsDisplay = true
    }

    private func toggleFold(_ region: FoldRegion) {
        foldState.toggle(region, in: textStorage)
        updateRulerFolds()
        detectFolds()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        SyntaxOracle.shared.applyHighlighting(to: textStorage, range: fullRange, font: nil)
    }

    // MARK: - Current Line Highlight

    /// Clears previous temporary highlight and applies a new one for the current line.
    /// Uses layout-manager attribute for gutter sync + a custom clip view that draws
    /// a full-width highlight rect behind the text.
    private func updateCurrentLineHighlight() {
        guard let lm = layoutManager as? HighlightingLayoutManager else { return }

        guard ThemeSettings.shared.highlightCurrentLine,
              textStorage.length > 0 else {
            lm.lineHighlightColor = nil
            textView.needsDisplay = true
            return
        }

        lm.lineHighlightColor = ThemeSettings.shared.lineHighlightColor
        textView.needsDisplay = true
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        updateCurrentLineHighlight()
        lineNumberGutter?.needsDisplay = true
        updateStatusBar()

        // A normal (non-programmatic) collapse back to a single selection means
        // the user has dismissed the multi-selection context — forget the ⌘D
        // occurrence literal so the next ⌘D starts a fresh search.
        if !isApplyingMultiSelection, textView.selectedRanges.count <= 1 {
            resetOccurrenceState()
        }

        // Search bar visible: keep it open but do NOT re-search on click.
        // User may click to inspect code while search remains active.
        // Navigation (Ctrl+S / Shift+Ctrl+S) still works from current match.
    }

    // MARK: - Theme Chrome

    /// Sets the background color of the code area only (scrollView/contentView).
    /// Called from MainWindowController to give the code pane its own opaque
    /// background distinct from the splitView's rulerColor surface behind the gutter.
    func applyThemeChrome() {
        richDocument.refreshTheme()
        let theme = ThemeRegistry.shared.current
        let settings = ThemeSettings.shared

        // ── Selection color with transparency ──
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectionColor.withAlphaComponent(0.35),
        ]

        let ft = currentFile.map { FileType(ext: $0.pathExtension) } ?? .unknown
        var font = settings.resolvedFont(for: ft)

        // ── ScopeSettings overlay: per-language overrides from .aether-properties ──
        if let file = currentFile,
           let scope = TreeSitterScopeMapper.scope(forExtension: file.pathExtension) {
            let ss = ScopeSettings.shared

            // Appearance & theme — apply before reading current theme (may change it)
            if let appearance = ss.resolveAppearance(scope: scope) {
                switch appearance.lowercased() {
                case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                default: break
                }
            }
            if let themeName = ss.resolveThemeName(scope: scope) {
                ThemeRegistry.shared.activate(named: themeName)
            }

            if let scopeFont = ss.resolveFont(scope: scope) {
                font = scopeFont
            } else if let scopeSize = ss.resolveFontSize(scope: scope) {
                // `fontSize`-only override (no `fontName`): keep the resolved face
                // and change its size, so per-filetype sizes in `.aether-properties`
                // actually take effect and cascade to the line-number column.
                let desc = font.fontDescriptor.withSize(CGFloat(scopeSize))
                font = NSFont(descriptor: desc, size: CGFloat(scopeSize)) ?? font
            }
            // softWrap: per-window override → .aether-properties → default true.
            if let showInvis = ss.resolveShowInvisibles(scope: scope) {
                layoutManager?.showsInvisibleCharacters = showInvis
            }
            if let spell = ss.resolveSpellChecking(scope: scope) {
                textView.isContinuousSpellCheckingEnabled = spell
            }
            // Apply per-scope softWrap (or global fallback) when file scope changes
            applyWordWrap()
        }

        // Don't set textView.textColor — it acts as typingAttributes and
        // overrides per-range .foregroundColor when isRichText is true.
        // Relies on SyntaxOracle.applyHighlighting to set all scopes.
        textView.insertionPointColor = theme.caretColor
        textView.font = font
        // Explicitly lock typingAttributes to base font — prevents NSTextView from
        // auto-deriving typing font from insertion-point attributes (e.g. heading size
        // leaking into next line after Return). Without this, when the cursor lands on
        // a heading line after async highlight, the large heading font becomes the
        // typing font for subsequent keystrokes.
        let typingParagraphStyle = NSMutableParagraphStyle()
        typingParagraphStyle.lineSpacing = settings.resolvedLineSpacing(for: theme)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: theme.editorForeground,
            .paragraphStyle: typingParagraphStyle
        ]
        SyntaxOracle.shared.baseFont = font   // clean base for fallback + multipliers

        // DIAGNOSTIC: Top inset 0 — let text underlap the toolbar for scroll-edge test.
        // Preserve glyph padding on theme changes; background painting extends to x=0.
        textView.textContainerInset = NSSize(width: EditorChromeMetrics.codeLeadingPadding, height: 0)
        if let ruler = lineNumberGutter {
            ruler.textColor = theme.editorForeground.withAlphaComponent(0.50)
            ruler.font = EditorGutterStyle.rulerFont(for: font)
            ruler.lineHighlightColor = settings.highlightCurrentLine ? settings.lineHighlightColor : nil
            ruler.separatorColor = theme.rulerSeparator
            // No solid background — gutterBlurView provides the blur material behind.
            ruler.rulerBackgroundColor = nil
            ruler.layer?.backgroundColor = nil
            ruler.layer?.isOpaque = false
            ruler.selectionBackground = theme.gutterSelectionBackground
            ruler.selectionForeground = theme.gutterSelectionForeground
            ruler.selectionBorder = theme.gutterSelectionBorder
            ruler.invalidateWidthCache()
        }
        if let hlm = layoutManager as? HighlightingLayoutManager {
            hlm.lineHighlightBorderColor = settings.highlightCurrentLine ? theme.lineHighlightBorder : nil
        }
        updateCurrentLineHighlight()

        // Text shadow: subtle depth only — the NSShadow KVC darkens all rendered text.
        // Kept near-zero; themes can override but dark backgrounds don't need a drop shadow.
        let shadowStrength = settings.resolvedTextShadow(for: theme)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowStrength)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3 * shadowStrength
        // Apply shadow only if there's meaningful strength, otherwise clear it
        if shadowStrength > 0.01 {
            textView.setValue(shadow, forKey: "shadow")
        } else {
            textView.setValue(nil, forKey: "shadow")
        }

        // ── Search bar follows theme when visible (SwiftUI observes chrome.theme) ──

        let spacing = settings.resolvedLineSpacing(for: theme)
        if let ps = NSParagraphStyle.default.mutableCopy() as? NSMutableParagraphStyle {
            ps.lineSpacing = spacing
            textView.defaultParagraphStyle = ps
        }

        // ── Code area background ──
        // The editor background is owned by the SwiftUI `TextKit2ScrollSurface`
        // as a fixed, full-size layer (a tint over the glass backdrop). The text
        // view must never paint its own background — `drawsBackground` here would
        // cover only the document extent and scroll/fade with the content, which
        // is exactly the "background only over the text area" artifact. Keep the
        // AppKit clip view transparent too, so nothing opaque sits between the
        // scroll edge effect and the glass.
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        
    }

    // MARK: - Document Operations

    /// Snapshot of the fully-highlighted document, independent of the
    /// NSTextView/NSLayoutManager pipeline. Feeds the SwiftUI TextKit 2 surface.
    func highlightedDocument() -> NSAttributedString {
        guard let storage = textStorage, storage.length > 0 else {
            return NSAttributedString()
        }
        return NSAttributedString(attributedString: storage)
    }

    /// Pushes the cached document shape. Called on every edit — the cache itself
    /// is maintained incrementally in `updateMetricsIncrementally` so this is O(1).
    private func pushDocumentMetrics() {
        onDocumentMetricsChange?(cachedLineCount, cachedMaxLineWidth)
    }

    /// Full-scan metric + line-index rebuild — used on document replace and theme
    /// re-highlight paths where an O(n) pass is already in flight.
    private func notifyDocumentChange() {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let metrics = Self.documentMetrics(for: text)
        cachedLineCount = metrics.lineCount
        cachedMaxLineWidth = metrics.maxLineWidth
        cachedMaxLineIndex = metrics.maxLineIndex
        lineStarts = metrics.lineStarts
        pushDocumentMetrics()
    }

    /// O(edited lines) metric maintenance for the keystroke path. Rescans the
    /// whole document only when the edit touches or shifts the current widest
    /// line — the one case where the old maximum may have shrunk or moved.
    private func updateMetricsIncrementally(changedRange: NSRange) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let replacedText = pendingReplacedText ?? ""
        let replacementText = pendingReplacementText ?? ""
        let lengthDelta = replacementText.length - replacedText.length
        let newlineDelta = Self.newlineCount(in: replacementText) - Self.newlineCount(in: replacedText)
        let editPoint = min(changedRange.location, ns.length)

        // ── Old-span bookkeeping (before the index mutates) ──
        // `oldEditPoint` is an OLD-text coordinate: clamp it against the old
        // length (new length − delta), never the new one, or a tail deletion
        // would binary-search a stale offset in the old index.
        let oldLength = max(0, ns.length - lengthDelta)
        let oldEditPoint = min(pendingEditRange.location == NSNotFound ? editPoint : pendingEditRange.location,
                               oldLength)
        let oldFirst = Self.lineIndex(at: oldEditPoint, lineStarts: lineStarts)
        let oldLast = oldFirst + Self.newlineCount(in: replacedText)

        // ── Line-start index maintenance — O(edit), on EVERY edit ──
        // Offsets shift by the length delta even when no newline is involved:
        // typing on one line moves every later line's start. The rebuilt block
        // keeps the edited line's ORIGINAL start (the line containing the edit
        // point does not move) and appends the starts of lines born inside the
        // inserted text; the tail shifts by the length delta.
        let idx = Self.lineIndex(at: editPoint, lineStarts: lineStarts)
        var rebuilt: [Int] = [lineStarts[idx]]
        var cursor = editPoint
        let editEnd = editPoint + replacementText.length
        while cursor < editEnd {
            if ns.character(at: cursor) == 0x0A { rebuilt.append(cursor + 1) }
            cursor += 1
        }
        // The tail begins after the old span's LAST touched line — a multi-line
        // replacement drops every intermediate line, not just the edited one.
        lineStarts = Array(lineStarts[..<idx]) + rebuilt
            + lineStarts[(oldLast + 1)...].map { $0 + lengthDelta }
        cachedLineCount = lineStarts.count

        // ── Widest-line maintenance ──
        let editTouchesMaxLine = oldFirst <= cachedMaxLineIndex && cachedMaxLineIndex <= oldLast
        let editAboveMaxLine = oldLast < cachedMaxLineIndex

        if editTouchesMaxLine {
            // The widest line was edited (or removed) — rescan to stay exact.
            let metrics = Self.documentMetrics(for: ns)
            cachedMaxLineWidth = metrics.maxLineWidth
            cachedMaxLineIndex = metrics.maxLineIndex
            lineStarts = metrics.lineStarts
        } else {
            if editAboveMaxLine { cachedMaxLineIndex += newlineDelta }
            let touchedLines = ns.lineRange(for: changedRange)
            let touchedFirst = Self.lineIndex(at: touchedLines.location, lineStarts: lineStarts)
            var maxTouched = 0
            var maxTouchedIndex = touchedFirst
            var cursor = touchedLines.location
            let touchedEnd = min(NSMaxRange(touchedLines), ns.length)
            var lineIndex = touchedFirst
            while cursor <= touchedEnd {
                let start = cursor
                while cursor < ns.length && ns.character(at: cursor) != 0x0A { cursor += 1 }
                let width = cursor - start
                if width > maxTouched {
                    maxTouched = width
                    maxTouchedIndex = lineIndex
                }
                if cursor >= touchedEnd { break }
                cursor += 1
                lineIndex += 1
            }
            if maxTouched > cachedMaxLineWidth {
                cachedMaxLineWidth = maxTouched
                cachedMaxLineIndex = maxTouchedIndex
            }
        }
    }

    /// 0-based line index for a UTF-16 offset via binary search over line starts.
    private static func lineIndex(at offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(0, low - 1)
    }

    private static func newlineCount(in text: NSString) -> Int {
        var count = 0
        var i = 0
        while i < text.length {
            if text.character(at: i) == 0x0A { count += 1 }
            i += 1
        }
        return count
    }

    /// Pushes the fully-highlighted snapshot — used only when the document is
    /// replaced (load/new/reload), where the passive render path may need it.
    private func notifyDocumentReplaced() {
        notifyDocumentChange()
        onDocumentChange?(highlightedDocument())
    }

    /// One-pass line count + widest line + line-start index. O(n) char scan of
    /// the plain string — no attributed copy, no attribute-run traversal, no
    /// layout. Used on document replace and the rare widest-line rescan.
    private static func documentMetrics(for text: NSString)
        -> (lineCount: Int, maxLineWidth: Int, maxLineIndex: Int, lineStarts: [Int]) {
        guard text.length > 0 else { return (1, 0, 0, [0]) }
        var lineCount = 1
        var maxWidth = 0
        var maxLineIndex = 0
        var lineStarts: [Int] = [0]
        var currentIndex = 0
        var lineStart = 0
        var i = 0
        while i <= text.length {
            if i == text.length || text.character(at: i) == 0x0A {
                let width = i - lineStart
                if width > maxWidth {
                    maxWidth = width
                    maxLineIndex = currentIndex
                }
                if i < text.length {
                    lineCount += 1
                    lineStarts.append(i + 1)
                    currentIndex += 1
                }
                lineStart = i + 1
            }
            i += 1
        }
        return (lineCount, maxWidth, maxLineIndex, lineStarts)
    }

    /// `conjure` distinguishes a *fresh window* (⌘N, the first tab) from a
    /// *new tab* (⌘⇧N). Only a fresh window honours the Flash code-poetry
    /// setting; a new tab is always a blank, untitled document — code poetry
    /// belongs to the birth of a window, not the birth of a tab.
    func newDocument(conjure: Bool = true) {
        guard confirmReplacingRichDocument() else { return }
        richDocument.active = false
        imagePreview.clear()
        guard let tv = textView else {
            print("[EditorViewController] textView nil — view not loaded")
            return
        }
        backgroundParseWork?.cancel()
        backgroundParseProgress = 0.0
        isLargeFile = false
        foldState.clear()

        // New-window contract (GeneralSettings): a blank pane or a flash
        // conjuration. Blank = truly empty, plain text; flash = placeholder
        // that the Oracle replaces asynchronously.
        let mode = conjure ? GeneralSettings.shared.newFileMode : .blank
        currentLanguageName = mode == .blank ? "Plain Text" : "Swift"
        SyntaxOracle.shared.setLanguage(forExtension: mode == .blank ? "text" : "swift")
        // suppressTextDidChange managed by caller
        tv.string = mode == .blank ? "" : exampleCode
        currentFile = nil
        isDirty = false
        layoutManager?.ghostSuggestion = nil
        layoutManager?.removeAllInlineBoxes()
        highlightFullDocument()
        detectFolds()
        updateTitle()
        updateStatusBar()
        notifyDocumentReplaced()

        // ZIEL A — the window never stays a mere placeholder: a fresh hermetic
        // "hello æther" script is conjured asynchronously. The synchronous
        // path above remains the fallback — fail-soft, never blocking.
        if mode == .flash {
            scheduleFlashConjuration()
        }
    }

    /// ZIEL A — Flash-AI-Neufenser. The synchronous placeholder is already in
    /// the text view; this replaces it asynchronously. All Oracle traffic runs
    /// off the main thread via a detached task.
    private func scheduleFlashConjuration() {
        flashTask?.cancel()
        flashGeneration += 1
        let generation = flashGeneration
        let root = RubyBridge.shared.projectRoot
        flashTask = Task.detached(priority: .utility) { [weak self] in
            let language = GeneralSettings.shared.resolvedLanguage(root: root)
            let code: String
            do {
                code = try await FlashAetherConjurer.summon(language: language)
            } catch {
                return // Oracle failed or timed out — the placeholder remains.
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.applyFlashConjuration(code: code, language: language, generation: generation)
            }
        }
    }

    /// Replaces the placeholder with the conjured script iff the document is
    /// still the untouched placeholder of the same generation (no file opened,
    /// no user edits in between).
    private func applyFlashConjuration(code: String, language: String, generation: Int) {
        guard generation == flashGeneration, !isDirty, currentFile == nil,
              let tv = textView else { return }
        currentLanguageName = TreeSitterScopeMapper.language(forExtension: language) ?? language.capitalized
        SyntaxOracle.shared.setLanguage(forExtension: language)
        suppressTextDidChange = true
        tv.string = code
        suppressTextDidChange = false
        isDirty = false
        layoutManager?.ghostSuggestion = nil
        highlightFullDocument()
        detectFolds()
        updateTitle()
        updateStatusBar()
        notifyDocumentReplaced()
    }

    func openFile(_ url: URL) {
            Task { @MainActor in AetherContext.shared.activate(for: url) }
            guard confirmReplacingRichDocument() else { return }
           
            // ── Image preview: raster files route to the viewer, not the text path ──
            if ImageFileType.isImage(url) {
                presentImage(url)
                return
            }
            // ── HTML preview: web documents route to the WebKit viewer ──
            if HTMLFileType.isHTML(url) {
                presentHTML(url)
                return
            }
            imagePreview.clear()
            htmlPreview.clear()
           
            guard let tv = textView else {
                print("[EditorViewController] textView nil — view not loaded")
                return
            }
    
            if ["rtf", "md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
                do {
                    let data = try Data(contentsOf: url)
                    try richDocument.load(data, markdown: url.pathExtension.lowercased() != "rtf")
                    backgroundParseWork?.cancel()
                    currentFile = url
                    currentLanguageName = richDocument.markdown ? "Markdown · Text" : "Rich Text"
                    isDirty = false
                    updateTitle()
                    notifyDocumentChange()
                } catch { NSApp.presentError(error) }
                return
            }

            // Binary detection — check first 4KB for null bytes
            if isBinaryFile(url) {
                let alert = NSAlert()
                alert.messageText = "Binary File Detected"
                alert.informativeText = "\(url.lastPathComponent) appears to be a binary file. It may contain non-text data that cannot be safely displayed. Do you want to open it anyway?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Anyway")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    // User cancelled — leave editor unchanged
                    return
                }
                // User chose "Open Anyway" — fall through to normal open path
            }
    
            do {
                // Clear line highlight before swapping text storage to prevent stale-range crash
                let hlm = layoutManager as? HighlightingLayoutManager
                hlm?.lineHighlightColor = nil
                foldState.clear()
                SyntaxOracle.shared.setLanguage(forExtension: url.pathExtension)
                currentLanguageName = TreeSitterScopeMapper.language(forExtension: url.pathExtension)
                    .map { $0.capitalized }
                    ?? FileType(ext: url.pathExtension).displayName
                let source = try String(contentsOf: url, encoding: .utf8)
                suppressTextDidChange = true
                richDocument.active = false
                tv.string = source
                suppressTextDidChange = false
                // Force ruler to recalculate line count + redraw after content swap
                lineNumberGutter?.needsDisplay = true
                currentFile = url
                isDirty = false
                updateTitle()
                applyThemeChrome()

                // ── Large file: viewport-only highlight + background parse ──
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                isLargeFile = fileSize > Self.largeFileThreshold

                if isLargeFile {
                    // Cancel any previous background parse
                    backgroundParseWork?.cancel()
                    backgroundParseProgress = 0.0

                    // Highlight visible range only (fast initial render)
                    highlightVisibleRange()

                    // Background: parse full document in chunks, reporting progress
                    scheduleBackgroundParse(for: tv.string)
                } else {
                    highlightFullDocument()
                }

                detectFolds()
                notifyDocumentReplaced()
            } catch {
                print("Failed to open: \(error)")
            }
        }
    
        /// Check if a file appears to be binary (contains null bytes in first 4KB).
        private func isBinaryFile(_ url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096) else { return false }
            return data.contains(0)
        }

    /// Routes an image file into the raster viewer, leaving text/rich-text
    /// state clean so the SwiftUI surface swaps back without stale text.
    private func presentImage(_ url: URL) {
        backgroundParseWork?.cancel()
        foldState.clear()
        richDocument.active = false
        imagePreview.onDirtyChange = { [weak self] dirty in
            guard let self else { return }
            self.isDirty = dirty
            self.updateTitle()
        }
        imagePreview.load(url: url)
        currentFile = url
        currentLanguageName = "Image"
        isDirty = false
        updateTitle()
        updateStatusBar()
    }

    /// Routes an HTML file into the WebKit preview, leaving text/rich-text
    /// state clean so the SwiftUI surface swaps back without stale text.
    private func presentHTML(_ url: URL) {
        backgroundParseWork?.cancel()
        foldState.clear()
        richDocument.active = false
        imagePreview.clear()
        htmlSourceLoadedFor = nil
        htmlPreview.loadFile(url: url)
        currentFile = url
        currentLanguageName = "HTML"
        isDirty = false
        updateTitle()
        updateStatusBar()
    }

    /// Leaves the WebKit preview and shows the raw HTML source in the code editor.
    /// If the source is already resident in the text view (e.g. after editing then
    /// previewing), it is preserved rather than re-read from disk.
    func showHTMLSource() {
        guard let url = htmlPreview.url ?? currentFile else { return }
        if htmlSourceLoadedFor == url, let tv = textView, !tv.string.isEmpty {
            htmlPreview.clear()
            currentLanguageName = "HTML"
            updateTitle()
            updateStatusBar()
            return
        }
        guard let tv = textView else { return }
        do {
            let hlm = layoutManager as? HighlightingLayoutManager
            hlm?.lineHighlightColor = nil
            foldState.clear()
            SyntaxOracle.shared.setLanguage(forExtension: url.pathExtension)
            currentLanguageName = "HTML"
            richDocument.active = false
            let source = try String(contentsOf: url, encoding: .utf8)
            suppressTextDidChange = true
            tv.string = source
            suppressTextDidChange = false
            lineNumberGutter?.needsDisplay = true
            currentFile = url
            isDirty = false
            updateTitle()
            applyThemeChrome()
            highlightFullDocument()
            detectFolds()
            notifyDocumentReplaced()
            htmlSourceLoadedFor = url
        } catch { NSApp.presentError(error) }
    }

    /// Re-enters WebKit preview from source mode, rendering the *current* editor
    /// contents (so unsaved edits are reflected) with the file's directory as the
    /// base URL for relative assets.
    func previewHTML() {
        guard let url = currentFile, HTMLFileType.isHTML(url) else { return }
        backgroundParseWork?.cancel()
        richDocument.active = false
        imagePreview.clear()
        let source = textView?.string ?? ""
        htmlSourceLoadedFor = url
        htmlPreview.loadHTML(source, baseURL: url)
        currentFile = url
        currentLanguageName = "HTML"
        isDirty = false
        updateTitle()
        updateStatusBar()
    }

    func saveDocument() {
        if imagePreview.isActive {
            let dims = imagePreview.pixelSize.map { "\(Int($0.width))×\(Int($0.height)) px" } ?? "—"
            let format = imagePreview.originalFormat.displayName
            onStatusChange?(dims, format, "Image", isDirty)
            return
        }
        if htmlPreview.isActive {
            onStatusChange?("Web Preview", "HTML", "HTML", isDirty)
            return
        }
        if htmlPreview.isActive { return }
        guard let url = currentFile else { return }
        do {
            if richDocument.active {
                try richDocument.encoded().write(to: url, options: .atomic)
            } else {
                try textView.string.write(to: url, atomically: true, encoding: .utf8)
            }
            isDirty = false
            updateTitle()
        } catch {
            NSApp.presentError(error)
        }
    }

    private func confirmReplacingRichDocument() -> Bool {
        let imageDirty = imagePreview.isActive && imagePreview.isDirty
        guard isDirty, richDocument.active || supportsRichText || imageDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(currentFile?.lastPathComponent ?? "this document")?"
        alert.informativeText = "Opening another document will replace the current text."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument()
            return !isDirty
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func updateTitle() {
        let name = currentFile?.lastPathComponent ?? "Untitled"
        let dirty = isDirty ? " \u{2022}" : ""
        let title = "\(name)\(dirty)"
        view.window?.title = title
        onTitleChange?(title)
        updateStatusBar()
    }

    // MARK: - Status Bar

    /// Post status info via `onStatusChange` (line/col, indent, language, dirty)
    /// so the chrome can mirror it. Also callable directly when the active tab
    /// switch must re-publish immediately (see `TabsModel.refreshStatus`).
    func updateStatusBar() {
        if imagePreview.isActive {
            let dims = imagePreview.pixelSize.map { "\(Int($0.width))×\(Int($0.height)) px" } ?? "—"
            let format = imagePreview.originalFormat.displayName
            onStatusChange?(dims, format, "Image", isDirty)
            return
        }
        let lineCol: String = {
            guard let tv = textView, tv.string.count > 0 else {
                return "Ln 1, Col 1"
            }
            let nsStr = tv.string as NSString
            let sel = tv.selectedRange().location
            var line = 1, pos = 0
            while pos < sel && pos < nsStr.length {
                let lr = nsStr.lineRange(for: NSRange(location: pos, length: 0))
                pos = NSMaxRange(lr)
                if pos <= sel { line += 1 }
            }
            let lineStart = line > 0 ? nsStr.lineRange(for: NSRange(location: sel, length: 0)).location : 0
            let col = max(1, sel - lineStart + 1)
            return "Ln \(line), Col \(col)"
        }()

        let tabInfo: String = {
    return "Tab: 4"
}()
        onStatusChange?(lineCol, tabInfo, currentLanguageName, isDirty)
    }

    // MARK: - Syntax Highlighting

    private func highlightFullDocument() {
        rehighlight()
    }

    /// Highlight only the visible range + buffer (±2000 chars), used for large files.
    private func highlightVisibleRange() {
        guard let tv = textView, let storage = textStorage, storage.length > 0 else { return }
        let layout = tv.layoutManager!
        let tc = tv.textContainer!
        let visibleRect = scrollView.contentView.bounds
        let visibleGlyphRange = layout.glyphRange(forBoundingRect: visibleRect, in: tc)
        let visibleCharRange = layout.characterRange(forGlyphRange: visibleGlyphRange,
                                                       actualGlyphRange: nil)
        let buf = 2000
        let loc = max(0, visibleCharRange.location - buf)
        let end = min(storage.length, visibleCharRange.location + visibleCharRange.length + buf)
        if end > loc {
            SyntaxOracle.shared.applyHighlighting(to: storage,
                                                   range: NSRange(location: loc, length: end - loc),
                                                   font: nil)
        }
    }

    /// Schedule a background parse that progressively highlights the full document in chunks.
    /// Reports progress via `backgroundParseProgress` for status bar display.
    private func scheduleBackgroundParse(for text: String) {
        backgroundParseWork?.cancel()

        let totalLen = text.count
        let chunkSize = 50_000 // highlight 50K chars at a time
        guard totalLen > chunkSize else {
            // Small enough — just do full highlight
            DispatchQueue.main.async { [weak self] in
                self?.highlightFullDocument()
                self?.backgroundParseProgress = 1.0
            }
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            for offset in stride(from: 0, to: totalLen, by: chunkSize) {
                // Check for cancellation
                if self.backgroundParseWork?.isCancelled == true { return }

                let loc = offset
                let end = min(offset + chunkSize + 2000, totalLen) // overlap for edge tokens
                let range = NSRange(location: loc, length: end - loc)

                DispatchQueue.main.sync {
                    guard let storage = self.textStorage, storage.length > 0 else { return }
                    SyntaxOracle.shared.applyHighlighting(to: storage, range: range, font: nil)
                }

                let progress = Double(min(offset + chunkSize, totalLen)) / Double(totalLen)
                DispatchQueue.main.async {
                    self.backgroundParseProgress = progress
                }

                // Yield to main thread every chunk
                Thread.sleep(forTimeInterval: 0.001)
            }

            DispatchQueue.main.async {
                self.backgroundParseProgress = 1.0
            }
        }

        backgroundParseWork = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    // MARK: - Ghost Text

    func showGhostSuggestion(_ text: String) {
        let insertionPoint = textView.selectedRange().location
        guard insertionPoint <= textStorage.length else { return }
        layoutManager?.ghostSuggestion = GhostSuggestion(text: text, insertionPoint: insertionPoint)
    }

    func clearGhostSuggestion() {
        layoutManager?.ghostSuggestion = nil
    }

    // MARK: - Inline Boxes

    func showInlineBox(kind: InlineBoxAttachment.Kind, message: String, at characterIndex: Int) {
        let box = InlineBoxAttachment(kind: kind, message: message)
        layoutManager?.insertInlineBox(box, at: characterIndex)
    }

    func clearInlineBoxes() {
        layoutManager?.removeAllInlineBoxes()
    }

    // MARK: - Incremental Search (Ctrl+S)

    @objc func toggleIncrementalSearch() {
        quickSearch.toggle()
    }

    /// Called from Edit → Find menu — navigates forward through search matches.
    @objc func searchNavigateForward() {
        if quickSearch.isVisible { quickSearch.next() }
    }

    /// Shift+Ctrl+S — navigates backward through search matches.
    @objc func searchNavigateBackward() {
        if quickSearch.isVisible { quickSearch.previous() }
    }

    // MARK: - Find & Replace (TextMate-style)

    @objc func showFindDialog(_ sender: Any?) { findReplace.show(replace: false) }
    @objc func showFindReplaceDialog(_ sender: Any?) { findReplace.show(replace: true) }
    @objc func useSelectionForFind(_ sender: Any?) { findReplace.useSelectionForFind() }
    @objc func findReplaceNext(_ sender: Any?) { findReplace.next() }
    @objc func findReplacePrevious(_ sender: Any?) { findReplace.previous() }
}

// MARK: - Standard Edit Actions

extension EditorViewController {

    // MARK: Comment syntax

    /// Line-comment token for the current file (or `nil` for languages that
    /// only support block comments / have no comments).
    private static func lineCommentToken(forExt ext: String) -> String? {
        switch ext {
        case "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm",
             "rs", "js", "jsx", "ts", "tsx", "go", "java", "kt", "kts",
             "scala", "cs", "php":
            return "//"
        case "rb", "py", "pyw", "sh", "bash", "zsh", "yaml", "yml", "toml",
             "pl", "pm", "r", "rbi":
            return "#"
        case "sql":
            return "--"
        default:
            return nil
        }
    }

    /// Block-comment delimiters for the current file, or `nil` when unsupported.
    private static func blockCommentTokens(forExt ext: String) -> (open: String, close: String)? {
        switch ext {
        case "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm",
             "rs", "js", "jsx", "ts", "tsx", "go", "java", "kt", "kts",
             "scala", "cs", "php", "css", "scss", "less":
            return ("/*", "*/")
        case "html", "htm", "xml", "plist", "svg", "md", "markdown", "mkdn", "mdown":
            return ("<!--", "-->")
        default:
            return nil
        }
    }

    private var currentFileExtension: String {
        if let ext = currentFile?.pathExtension.lowercased(), !ext.isEmpty { return ext }
        // New documents have no file — fall back to the resolved language name.
        switch currentLanguageName.lowercased() {
        case "swift": return "swift"
        case "ruby": return "rb"
        case "python": return "py"
        case "shell", "bash", "zsh": return "sh"
        case "javascript": return "js"
        case "typescript", "tsx": return "ts"
        default: return ""
        }
    }

    // MARK: Undo-aware text replacement

    /// Canonical programmatic edit: routes through `shouldChangeText` /
    /// `didChangeText` so the change is registered with the text view's undo
    /// manager and re-highlighting/fold detection run exactly once.
    private func replaceText(in range: NSRange, with string: String) {
        guard let ts = textStorage else { return }
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textStorage.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }

    // MARK: Line enumeration

    private struct LineEdit {
        let contentRange: NSRange
        let terminator: String
    }

    /// Enumerates full lines (content + terminator) covered by `range`.
    private func lineEdits(in range: NSRange) -> [LineEdit] {
        let ns = textView.string as NSString
        var edits: [LineEdit] = []
        var loc = range.location
        let limit = NSMaxRange(range)
        while loc < limit {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: loc, length: 0))
            let contentRange = NSRange(location: start, length: contentsEnd - start)
            let terminator = end > contentsEnd
                ? ns.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
                : ""
            edits.append(LineEdit(contentRange: contentRange, terminator: terminator))
            if end <= loc { break }
            loc = end
        }
        return edits
    }

    private static func leadingWhitespaceCount(_ s: String) -> Int {
        s.prefix(while: { $0.isWhitespace }).count
    }

    private static func isLineCommented(_ line: String, token: String) -> Bool {
        let ws = leadingWhitespaceCount(line)
        return line.dropFirst(ws).hasPrefix(token)
    }

    private static func commentLine(_ line: String, token: String) -> String {
        let ws = line.prefix(while: { $0.isWhitespace })
        let rest = line.dropFirst(ws.count)
        return String(ws) + token + " " + String(rest)
    }

    private static func uncommentLine(_ line: String, token: String) -> String {
        let ws = line.prefix(while: { $0.isWhitespace })
        var rest = String(line.dropFirst(ws.count))
        if rest.hasPrefix(token) {
            rest.removeFirst(token.count)
            if rest.first == " " { rest.removeFirst() }
            else if rest.first == "\t" { rest.removeFirst() }
        }
        return String(ws) + rest
    }

    // MARK: Comment actions

    /// ⌘/ — toggle line comments on the selected lines (or current line).
    @objc func toggleComment(_ sender: Any?) {
        guard textView != nil, textStorage.length > 0 else { return }
        guard let token = Self.lineCommentToken(forExt: currentFileExtension) else {
            NSSound.beep()
            return
        }
        let ns = textView.string as NSString
        var sel = textView.selectedRange()
        if sel.length > 0, sel.location + sel.length > 0,
           ns.substring(with: NSRange(location: sel.location + sel.length - 1, length: 1)) == "\n" {
            sel.length -= 1
        }
        let lineRange = ns.lineRange(for: sel)
        let edits = lineEdits(in: lineRange)
        guard !edits.isEmpty else { return }

        let allCommented = edits.allSatisfy {
            Self.isLineCommented(ns.substring(with: $0.contentRange), token: token)
        }

        var newText = ""
        for e in edits {
            let line = ns.substring(with: e.contentRange)
            if allCommented {
                newText += Self.uncommentLine(line, token: token) + e.terminator
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                newText += (trimmed.isEmpty ? line : Self.commentLine(line, token: token)) + e.terminator
            }
        }
        guard newText != ns.substring(with: lineRange) else { return }
        replaceText(in: lineRange, with: newText)
    }

    /// ⇧⌘/ — wrap/unwrap the selection (or current line) in a block comment.
    @objc func toggleBlockComment(_ sender: Any?) {
        guard textView != nil, textStorage.length > 0 else { return }
        guard let pair = Self.blockCommentTokens(forExt: currentFileExtension) else {
            NSSound.beep()
            return
        }
        let ns = textView.string as NSString
        var sel = textView.selectedRange()
        if sel.length == 0 {
            sel = ns.lineRange(for: sel)
        }
        let text = ns.substring(with: sel)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(pair.open) && trimmed.hasSuffix(pair.close) {
            var inner = text
            if let r = inner.range(of: pair.open) { inner.removeSubrange(r) }
            if let r = inner.range(of: pair.close, options: .backwards) { inner.removeSubrange(r) }
            replaceText(in: sel, with: inner)
        } else {
            replaceText(in: sel, with: pair.open + text + pair.close)
        }
    }

    // MARK: Indentation

    /// ⌘] — indent the selected lines (or insert a tab at the cursor).
    @objc func indentSelection(_ sender: Any?) {
        guard let textView else { return }
        let sel = textView.selectedRange()
        if sel.length == 0 {
            replaceText(in: sel, with: "\t")
            textView.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: sel)
        let edits = lineEdits(in: lineRange)
        let newText = edits.map { e in
            let line = ns.substring(with: e.contentRange)
            return (line.trimmingCharacters(in: .whitespaces).isEmpty ? line : "\t" + line) + e.terminator
        }.joined()
        if newText != ns.substring(with: lineRange) {
            replaceText(in: lineRange, with: newText)
        }
    }

    /// ⌘[ — outdent the selected lines.
    @objc func outdentSelection(_ sender: Any?) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = ns.lineRange(for: sel)
        let edits = lineEdits(in: lineRange)
        let newText = edits.map { e in
            var line = ns.substring(with: e.contentRange)
            if line.hasPrefix("\t") {
                line.removeFirst()
            } else if line.hasPrefix("    ") {
                line.removeFirst(4)
            }
            return line + e.terminator
        }.joined()
        if newText != ns.substring(with: lineRange) {
            replaceText(in: lineRange, with: newText)
        }
    }

    // MARK: Line operations

    /// ⇧⌘L — select the full current line(s).
    @objc func selectCurrentLine(_ sender: Any?) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        textView.setSelectedRange(lineRange)
    }

    // MARK: Multiple selections & column (box) selection

    /// ⌃⇧W — "Edit Each Line in Selection": replace the current (multi-line)
    /// selection with one caret per line, all anchored to the visual column of
    /// the selection's start. Lines shorter than the anchor column get a caret
    /// at their end. Typing then inserts at every caret simultaneously.
    @objc func editEachLineInSelection(_ sender: Any?) {
        guard textView != nil, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        var sel = textView.selectedRange()
        // Trim a trailing newline so a full-line selection doesn't spawn a caret
        // on an empty phantom line after the block.
        if sel.length > 0 {
            let lastLoc = sel.location + sel.length - 1
            if lastLoc < ns.length, ns.character(at: lastLoc) == 0x0A {
                sel.length -= 1
            }
        }
        let lineRange = ns.lineRange(for: sel)
        let edits = lineEdits(in: lineRange)
        guard !edits.isEmpty else { return }

        let anchorX = caretXOffset(at: sel.location)
        var ranges: [NSRange] = []
        for e in edits {
            let idx = insertionIndex(atColumnX: anchorX, inLine: e.contentRange)
            ranges.append(NSRange(location: idx, length: 0))
        }
        guard !ranges.isEmpty else { return }

        resetOccurrenceState()
        isApplyingMultiSelection = true
        textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .upstream, stillSelecting: false)
        isApplyingMultiSelection = false
        textView.scrollRangeToVisible(NSRange(location: ranges[0].location, length: 0))
    }

    /// ⌘D — "Select Next Occurrence": add the next match of the current
    /// selection (or word under the caret) to the set of selections.
    @objc func selectNextOccurrence(_ sender: Any?) {
        guard textView != nil, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        var ranges = textView.selectedRanges.map { $0.rangeValue }

        // First invocation derives the search literal from the selection or word.
        if occurrenceSearchString == nil {
            let primary = ranges.last ?? textView.selectedRange()
            let literal: String
            if primary.length > 0 {
                literal = ns.substring(with: primary)
            } else {
                let word = wordRange(at: primary.location)
                guard word.length > 0 else { NSSound.beep(); return }
                literal = ns.substring(with: word)
                ranges = [word]  // caret → whole-word selection
            }
            guard !literal.isEmpty else { NSSound.beep(); return }
            occurrenceSearchString = literal

            isApplyingMultiSelection = true
            textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .upstream, stillSelecting: false)
            isApplyingMultiSelection = false
        }

        guard let literal = occurrenceSearchString else { return }

        let lastEnd = ranges.last.map { NSMaxRange($0) } ?? 0
        let searchRange = NSRange(location: lastEnd, length: max(0, ns.length - lastEnd))
        var found = ns.range(of: literal, options: [], range: searchRange)
        if found.location == NSNotFound {
            // Wrap to the top.
            found = ns.range(of: literal, options: [], range: NSRange(location: 0, length: ns.length))
        }
        guard found.location != NSNotFound, found.length > 0 else { NSSound.beep(); return }
        guard !ranges.contains(where: { NSEqualRanges($0, found) }) else { NSSound.beep(); return }

        ranges.append(found)
        isApplyingMultiSelection = true
        textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .upstream, stillSelecting: false)
        isApplyingMultiSelection = false
        textView.scrollRangeToVisible(found)
    }

    /// ⌃⌘G — "Select All Occurrences": select every match of the current
    /// selection (or word under the caret) across the whole document at once.
    @objc func selectAllOccurrences(_ sender: Any?) {
        guard textView != nil, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        let primary = textView.selectedRanges.last?.rangeValue ?? textView.selectedRange()

        let literal: String
        if primary.length > 0 {
            literal = ns.substring(with: primary)
        } else {
            let word = wordRange(at: primary.location)
            guard word.length > 0 else { NSSound.beep(); return }
            literal = ns.substring(with: word)
        }
        guard !literal.isEmpty else { NSSound.beep(); return }
        resetOccurrenceState()

        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: literal, options: [], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            matches.append(found)
            let nextLoc = NSMaxRange(found)
            if nextLoc >= ns.length { break }
            searchRange = NSRange(location: nextLoc, length: ns.length - nextLoc)
        }
        guard !matches.isEmpty else { NSSound.beep(); return }

        isApplyingMultiSelection = true
        textView.setSelectedRanges(matches.map { NSValue(range: $0) }, affinity: .upstream, stillSelecting: false)
        isApplyingMultiSelection = false
        textView.scrollRangeToVisible(matches[0])
    }

    /// Esc — collapse all carets/selections back to the primary caret.
    func collapseMultipleSelections() {
        guard textView != nil else { return }
        resetOccurrenceState()
        columnSelectionActive = false
        isApplyingMultiSelection = true
        if let last = textView.selectedRanges.last?.rangeValue {
            textView.setSelectedRange(NSRange(location: last.location, length: 0))
        }
        isApplyingMultiSelection = false
    }

    // MARK: Option-click / Option-drag (column selection)

    func beginOptionMouse(at point: NSPoint) {
        guard textView != nil, textStorage.length > 0 else { return }
        let idx = textView.characterIndexForInsertion(at: point)
        let content = lineContentRange(at: idx)
        columnAnchorLineStart = content.location
        columnAnchorX = caretXOffset(at: idx)
        columnSelectionActive = true
    }

    func dragColumnSelection(to point: NSPoint) {
        guard columnSelectionActive, textStorage.length > 0 else { return }
        let idx = textView.characterIndexForInsertion(at: point)
        let content = lineContentRange(at: idx)
        let ranges = columnRanges(fromLineStart: columnAnchorLineStart, startX: columnAnchorX,
                                  toLineStart: content.location, endX: caretXOffset(at: idx))
        isApplyingMultiSelection = true
        textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .upstream, stillSelecting: true)
        isApplyingMultiSelection = false
    }

    func endColumnSelection(at point: NSPoint) {
        guard columnSelectionActive else { return }
        columnSelectionActive = false
        guard textStorage.length > 0 else { return }
        dragColumnSelection(to: point)
        isApplyingMultiSelection = true
        textView.setSelectedRanges(textView.selectedRanges, affinity: .upstream, stillSelecting: false)
        isApplyingMultiSelection = false
        resetOccurrenceState()
    }

    func toggleCaret(at point: NSPoint) {
        guard textView != nil, textStorage.length > 0 else { return }
        let idx = textView.characterIndexForInsertion(at: point)
        var ranges = textView.selectedRanges.map { $0.rangeValue }
        if let existing = ranges.firstIndex(where: { $0.length == 0 && $0.location == idx }) {
            ranges.remove(at: existing)
        } else {
            ranges.append(NSRange(location: idx, length: 0))
        }
        guard !ranges.isEmpty else { return }
        isApplyingMultiSelection = true
        textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .upstream, stillSelecting: false)
        isApplyingMultiSelection = false
        resetOccurrenceState()
    }

    func resetColumnSelectionIfNeeded() {
        columnSelectionActive = false
    }

    // MARK: Multi-selection geometry helpers

    private func resetOccurrenceState() {
        occurrenceSearchString = nil
    }

    private func wordRange(at location: Int) -> NSRange {
        guard textView != nil, textStorage.length > 0 else { return NSRange(location: location, length: 0) }
        return textView.selectionRange(forProposedRange: NSRange(location: location, length: 0),
                                       granularity: .selectByWord)
    }

    /// Content range (without line terminator) of the line containing `location`.
    private func lineContentRange(at location: Int) -> NSRange {
        let ns = textView.string as NSString
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                        for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// Visual column (x-offset from the line-fragment left edge, in points) of a
    /// caret at `index`. Uses the actual layout so tabs/wrapped glyphs are exact.
    private func caretXOffset(at index: Int) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        let len = textStorage.length
        guard len > 0 else { return 0 }
        let target = min(max(index, 0), len)
        let ns = textView.string as NSString
        // Caret at a newline or end-of-document sits after the previous character.
        if target > 0 && (target == len || ns.character(at: target) == 0x0A) {
            let prevGlyph = max(lm.glyphIndexForCharacter(at: target - 1), 0)
            let loc = lm.location(forGlyphAt: prevGlyph)
            let advance = lm.boundingRect(forGlyphRange: NSRange(location: prevGlyph, length: 1), in: tc).width
            let lineRect = lm.lineFragmentRect(forGlyphAt: prevGlyph, effectiveRange: nil)
            return (loc.x + advance) - lineRect.origin.x
        }
        let glyph = max(lm.glyphIndexForCharacter(at: target), 0)
        let loc = lm.location(forGlyphAt: glyph)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return loc.x - lineRect.origin.x
    }

    /// Insertion index on a line whose caret x-offset is closest to `x`.
    private func insertionIndex(atColumnX x: CGFloat, inLine lineRange: NSRange) -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return lineRange.location }
        guard lineRange.length > 0 else { return lineRange.location }
        let glyphIndex = lm.glyphIndexForCharacter(at: lineRange.location)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        var fraction: CGFloat = 0
        let pt = NSPoint(x: lineRect.origin.x + x, y: lineRect.origin.y + lineRect.height / 2)
        let idx = lm.characterIndex(for: pt, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let insertion = fraction < 0.5 ? idx : idx + 1
        return min(max(insertion, lineRange.location), NSMaxRange(lineRange))
    }

    /// Visual-column x of the end of a line's content (0 for empty lines).
    private func lineMaxXOffset(contentRange: NSRange) -> CGFloat {
        guard contentRange.length > 0 else { return 0 }
        return caretXOffset(at: NSMaxRange(contentRange))
    }

    /// Build the per-line selection ranges of a rectangular column block.
    /// Lines that end before the box's left edge are skipped (no caret).
    private func columnRanges(fromLineStart startLine: Int, startX: CGFloat,
                              toLineStart endLine: Int, endX: CGFloat) -> [NSRange] {
        let lowX = min(startX, endX)
        let highX = max(startX, endX)
        let firstLine = min(startLine, endLine)
        let lastLine = max(startLine, endLine)
        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        var loc = firstLine
        while loc <= lastLine {
            let content = lineContentRange(at: loc)
            let maxX = lineMaxXOffset(contentRange: content)
            if lowX <= maxX + 0.5 {
                let s = insertionIndex(atColumnX: lowX, inLine: content)
                let e = insertionIndex(atColumnX: highX, inLine: content)
                ranges.append(e > s ? NSRange(location: s, length: e - s) : NSRange(location: s, length: 0))
            }
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            if next <= loc { break }  // safety against infinite loop at end-of-doc
            loc = next
        }
        return ranges
    }

    /// ⌃⇧D — duplicate the selected lines (or current line).
    @objc func duplicateLine(_ sender: Any?) {
        guard textView != nil, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = ns.lineRange(for: sel)
        let text = ns.substring(with: lineRange)
        // Insert a duplicate after the block; keep cursor on the new copy.
        let insertRange = NSRange(location: NSMaxRange(lineRange), length: 0)
        replaceText(in: insertRange, with: text)
        textView.setSelectedRange(NSRange(location: NSMaxRange(lineRange), length: lineRange.length))
    }

    /// ⌃⌘↑ — move the current line(s) up one line.
    @objc func moveLineUp(_ sender: Any?) {
        moveSelectedLines(by: -1)
    }

    /// ⌃⌘↓ — move the current line(s) down one line.
    @objc func moveLineDown(_ sender: Any?) {
        moveSelectedLines(by: 1)
    }

    private func moveSelectedLines(by delta: Int) {
        guard textView != nil, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)

        if delta < 0 {
            // Move up: needs the previous line's terminator to swap across.
            guard lineRange.location > 0 else { NSSound.beep(); return }
            let prevRange = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let prev = ns.substring(with: prevRange)
            let combined = NSRange(location: prevRange.location, length: NSMaxRange(lineRange) - prevRange.location)
            replaceText(in: combined, with: block + prev)
            textView.setSelectedRange(NSRange(location: prevRange.location, length: block.count))
        } else {
            guard NSMaxRange(lineRange) < ns.length else { NSSound.beep(); return }
            let nextRange = ns.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0))
            let next = ns.substring(with: nextRange)
            let combined = NSRange(location: lineRange.location, length: NSMaxRange(nextRange) - lineRange.location)
            replaceText(in: combined, with: next + block)
            textView.setSelectedRange(NSRange(location: lineRange.location + next.count, length: block.count))
        }
    }

    /// ⌃J — join the current line with the following line.
    @objc func joinLines(_ sender: Any?) {
        guard let textView, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = ns.lineRange(for: sel)
        // If the join target is the last line, join with the previous instead.
        let targetEnd = NSMaxRange(lineRange)
        if targetEnd >= ns.length {
            guard lineRange.location > 0 else { NSSound.beep(); return }
            let prevRange = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let prevContent = ns.substring(with: NSRange(location: prevRange.location, length: prevRange.length - (prevRange.length > 0 && ns.substring(with: NSRange(location: prevRange.location + prevRange.length - 1, length: 1)) == "\n" ? 1 : 0)))
            let curContent = ns.substring(with: NSRange(location: lineRange.location, length: lineRange.length))
            let merged = prevContent + " " + curContent.trimmingCharacters(in: .whitespaces)
            let combined = NSRange(location: prevRange.location, length: NSMaxRange(lineRange) - prevRange.location)
            replaceText(in: combined, with: merged)
            textView.setSelectedRange(NSRange(location: prevRange.location + prevContent.count + 1, length: 0))
            return
        }
        let nextRange = ns.lineRange(for: NSRange(location: targetEnd, length: 0))
        let curContent = ns.substring(with: NSRange(location: lineRange.location, length: lineRange.length))
        let curTrimmed = curContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTrimmed = ns.substring(with: NSRange(location: nextRange.location, length: nextRange.length)).trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = curTrimmed + " " + nextTrimmed
        let combined = NSRange(location: lineRange.location, length: NSMaxRange(nextRange) - lineRange.location)
        replaceText(in: combined, with: merged)
        textView.setSelectedRange(NSRange(location: lineRange.location + curTrimmed.count + 1, length: 0))
    }

    // MARK: Line deletion / insertion

    /// ⌘⇧K — delete the current line(s).
    @objc func deleteLine(_ sender: Any?) {
        guard let textView, textStorage.length > 0 else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let lineRange = ns.lineRange(for: sel)
        // Deleting the very last line (no trailing newline) also eats the
        // previous line's terminator so the cursor lands at the new last line.
        var range = lineRange
        if NSMaxRange(lineRange) >= ns.length, lineRange.location > 0 {
            range = NSRange(location: lineRange.location - 1, length: lineRange.length + 1)
        }
        replaceText(in: range, with: "")
        let newLen = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(range.location, newLen), length: 0))
    }

    /// ⌘↩ — insert a blank line below the current line/selection.
    @objc func insertLineBelow(_ sender: Any?) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        let end = NSMaxRange(lineRange)
        replaceText(in: NSRange(location: end, length: 0), with: "\n")
        textView.setSelectedRange(NSRange(location: end + 1, length: 0))
    }

    /// ⇧⌘↩ — insert a blank line above the current line/selection.
    @objc func insertLineAbove(_ sender: Any?) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        replaceText(in: NSRange(location: lineRange.location, length: 0), with: "\n")
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
    }

    // MARK: Case transforms

    /// ⌃⇧U — uppercase the selection (or the word under the cursor).
    @objc func uppercaseSelection(_ sender: Any?) {
        transformSelection { $0.uppercased() }
    }

    /// ⌃⇧L — lowercase the selection (or the word under the cursor).
    @objc func lowercaseSelection(_ sender: Any?) {
        transformSelection { $0.lowercased() }
    }

    private func transformSelection(_ transform: (String) -> String) {
        guard let textView, textStorage.length > 0 else { return }
        var sel = textView.selectedRange()
        if sel.length == 0 {
            sel = textView.selectionRange(forProposedRange: NSRange(location: sel.location, length: 0),
                                          granularity: .selectByWord)
        }
        guard sel.length > 0 else { NSSound.beep(); return }
        let ns = textView.string as NSString
        let original = ns.substring(with: sel)
        let transformed = transform(original)
        guard transformed != original else { return }
        replaceText(in: sel, with: transformed)
        textView.setSelectedRange(NSRange(location: sel.location, length: (transformed as NSString).length))
    }

    // MARK: Navigation

    /// ⌘L — jump to a line number.
    @objc func goToLine(_ sender: Any?) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number (1–\(ns.length == 0 ? 1 : lineCount(ns)))."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let num = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), num > 0 else { return }
        let target = min(num - 1, lineCount(ns) - 1)
        let idx = lineIndex(ns, lineNumber: target)
        textView.setSelectedRange(NSRange(location: idx, length: 0))
        textView.scrollRangeToVisible(NSRange(location: idx, length: 0))
    }

    private func lineCount(_ ns: NSString) -> Int {
        var count = 0
        var loc = 0
        while loc < ns.length {
            var end = 0
            ns.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: loc, length: 0))
            count += 1
            if end <= loc { break }
            loc = end
        }
        return count
    }

    private func lineIndex(_ ns: NSString, lineNumber: Int) -> Int {
        var loc = 0
        var line = 0
        while loc < ns.length && line < lineNumber {
            var end = 0
            ns.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: loc, length: 0))
            if end <= loc { break }
            loc = end
            line += 1
        }
        return loc
    }

    /// Selects and reveals the given 1-based line without an alert — used by
    /// project-scope find results to jump straight to a match.
    func revealLine(_ lineNumber: Int) {
        guard let textView else { return }
        let ns = textView.string as NSString
        guard lineNumber > 0, ns.length > 0 else { return }
        let target = min(lineNumber - 1, lineCount(ns) - 1)
        let idx = lineIndex(ns, lineNumber: target)
        textView.setSelectedRange(NSRange(location: idx, length: 0))
        textView.scrollRangeToVisible(NSRange(location: idx, length: 0))
    }

    // MARK: Invisibles

    /// ⌃⌥I — toggle visible whitespace / control characters.
    @objc func toggleInvisibles(_ sender: Any?) {
        guard let textView else { return }
        let lm = textView.layoutManager
        let next = !(lm?.showsInvisibleCharacters ?? false)
        lm?.showsInvisibleCharacters = next
        lm?.showsControlCharacters = next
        textView.needsDisplay = true
    }
}

// MARK: - NSTextViewDelegate
extension EditorViewController: NSTextViewDelegate {
    /// Guard against re-entrant textDidChange from processEditing cascade.
    private var isHighlighting: Bool {
        get { objc_getAssociatedObject(self, &Reentrancy.highlightKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &Reentrancy.highlightKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Expected cursor location after the current edit commits.
    /// Captured in shouldChangeTextIn and consumed in textDidChange
    /// so we can restore it after attribute changes perturb the insertion point.
    private var expectedPostEditCursor: Int? {
        get { objc_getAssociatedObject(self, &Reentrancy.cursorEditKey) as? Int }
        set { objc_setAssociatedObject(self, &Reentrancy.cursorEditKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressTextDidChange, !isHighlighting else { return }
        // dismissTitlebar() — disabled until scroll-edge is stable
        isDirty = true
        updateTitle()

        // ── Keystroke path: O(edited lines), never O(document) ──
        // The edit is confined to the line range below (plus one line of context
        // on each side, so a block-comment opener on the previous line keeps its
        // scope while typing). Tree-sitter, fence pairing and injection layers
        // converge in the debounced full pass once the typing pauses.
        let storage = textStorage!
        let ns = storage.string as NSString
        let editLocation = pendingEditRange.location == NSNotFound ? 0 : pendingEditRange.location
        let replacementLen = min(pendingReplacementText?.length ?? 0, max(0, ns.length - editLocation))
        let changedRange = NSRange(location: min(editLocation, ns.length), length: replacementLen)
        let editLineRange = ns.lineRange(for: changedRange)
        let contextRange = Self.extendedLineRange(editLineRange, byLines: 1, in: ns)

        isHighlighting = true
        (layoutManager as? HighlightingLayoutManager)?.isApplyingHighlighting = true
        defer {
            isHighlighting = false
            (layoutManager as? HighlightingLayoutManager)?.isApplyingHighlighting = false
        }
        if contextRange.length > 0 {
            SyntaxOracle.shared.applyEditingHighlight(to: storage, range: contextRange, font: nil)
        }

        // Arm the full-document convergence pass for the typing pause.
        highlightDebounce?.invalidate()
        highlightDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.rehighlight()
        }

        // Restore cursor to the position computed in shouldChangeTextIn.
        // Attribute changes (setAttributes/addAttributes) perturb the insertion
        // point's pixel position because bold/heading fonts have different glyph
        // widths in proportional text. The character index should be stable, but
        // processEditing can drift it by ±1. Pin it back.
        if let pos = expectedPostEditCursor, pos <= storage.length {
            textView.setSelectedRange(NSRange(location: pos, length: 0))
        }
        expectedPostEditCursor = nil

        updateMetricsIncrementally(changedRange: changedRange)
        pushDocumentMetrics()

        clearGhostSuggestion()

        foldDetectionDebounce?.invalidate()
        foldDetectionDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.detectFolds()
        }
    }

    /// Line range extended outward by `byLines` lines on both sides, clamped to
    /// the document bounds. Used by the keystroke highlight so an edit near a
    /// construct boundary (block comment, fence) keeps its opening line colored.
    private static func extendedLineRange(_ lineRange: NSRange, byLines: Int, in ns: NSString) -> NSRange {
        var start = lineRange.location
        var end = NSMaxRange(lineRange)
        var extended = byLines
        while start > 0 && extended > 0 {
            start -= 1
            if ns.character(at: start) == 0x0A { extended -= 1 }
        }
        extended = byLines
        while end < ns.length && extended > 0 {
            if ns.character(at: end) == 0x0A { extended -= 1 }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Strip rich formatting on paste — we manage all attributes ourselves.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Multi-caret typing: NSTextView inserts at every caret itself. Pinning a
        // single `expectedPostEditCursor` here would collapse the sibling carets
        // in `textDidChange`, so we only pin when there is exactly one selection.
        // Multi-caret paste is likewise left to the native fan-out path.
        let isMultiCaret = textView.selectedRanges.count > 1
        if !isMultiCaret {
            let len = (replacementString as NSString?)?.length ?? 0
            expectedPostEditCursor = affectedCharRange.location + len
            // Capture the edit context while the OLD text is still live — the
            // incremental keystroke path in `textDidChange` needs both sides.
            pendingEditRange = affectedCharRange
            pendingReplacementText = replacementString as NSString?
            pendingReplacedText = (textView.string as NSString).substring(with: affectedCharRange) as NSString
        }

        guard !isHandlingPaste, !isMultiCaret,
              let replacement = replacementString,
              replacement.count > 1,                    // single chars are typing, not paste
              let currentPasteboardString = NSPasteboard.general.string(forType: .string),
              replacement == currentPasteboardString    // only intercept actual pasteboard paste
        else { return true }

        isHandlingPaste = true
        textView.insertText(replacement, replacementRange: affectedCharRange)
        isHandlingPaste = false
        return false // we handled it
    }
}

// MARK: - NSTextFieldDelegate (Rename)

extension EditorViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissRenameField()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitRename((control as? NSTextField)?.stringValue ?? "")
            return true
        }
        return false
    }
    
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        // Commit on focus loss (tab, click away)
        commitRename((control as? NSTextField)?.stringValue ?? "")
        return true
    }
}

// MARK: - Welcome Example

private let exampleCode = """
// ÆtherCodex — the veil parts
func conjure(name: String, power: Double = 0.5) -> String {
    let sigil = "✦ \\(name) ✦"
    let potency = power * 100.0  // amplifica
    if potency > 75.0 {
        return "\\(sigil) :: \\(potency)%%"
    }
    return "\\(sigil) :: glyph unclear"
}

struct Codex {
    var pages: Int
    let bound: Bool = true
    /* sealed */ var wards: [String]
}

let oracle = Codex(pages: 7, wards: ["fire", "shadow", "glass"])

for ward in oracle.wards where ward != "glass" {
    print(conjure(name: ward, power: 0.82))
}
// The serpent compiles in silence
"""