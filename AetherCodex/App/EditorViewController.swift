import Cocoa
import CSafeLayout

// MARK: - HermeticTextView

/// NSTextView subclass that wraps draw(_:) in SafeCallBlock to prevent
/// SIGILL crashes from AppKit private layout methods when the glyph tree
/// is transiently inconsistent after text storage mutations.
private final class HermeticTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        if !SafeCallBlock({ super.draw(dirtyRect) }) {
            backgroundColor.setFill()
            dirtyRect.fill()
        }
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

    // MARK: - Hermetic Text Pipeline

    private var layoutManager: HighlightingLayoutManager?
    private(set) var textStorage: NSTextStorage!
    private var settingsObserver: NSObjectProtocol?
    private var themeObserver:    NSObjectProtocol?

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
    /// gutter width + textContainerInset.x (8px). Used for titlebar spacer alignment.
    var effectiveGutterWidth: CGFloat {
        (lineNumberGutter?.gutterWidth ?? 52) + 8
    }

    // MARK: - Incremental Search (Ctrl+S)

    var incrementalSearchBar: IncrementalSearchBar!
    private var searchMatches: [NSRange] = []
    private var currentSearchIndex: Int = 0
    private var preSearchSelection: NSRange?
    private var searchOrigin: Int = 0

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
        incrementalSearchBar = IncrementalSearchBar(frame: .zero)
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
        ThemeRegistry.shared.onChange = { [weak self] in
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
        textView.textContainerInset = NSSize(width: 8, height: 28)
        textView.delegate = self

        // Disable macOS smart quotes/dashes — code editor, not word processor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Ctrl+Shift+P → scope inspector; Ctrl+S → search; Shift+Ctrl+S → prev
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.view.window?.isKeyWindow == true else { return event }

            // ── Auto-recover focus: if window is key but text view lost responder
            //     (e.g., user clicked glass titlebar or dismissed search), restore it.
            if !self.incrementalSearchBar.isVisible,
               let fr = self.view.window?.firstResponder,
               fr !== self.textView,
               !(fr is NSText) {
                self.view.window?.makeFirstResponder(self.textView)
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
               self.incrementalSearchBar.isVisible {
                self.navigateSearch(forward: false)
                return nil
            }

            // ── Esc while search bar visible ──
            if self.incrementalSearchBar.isVisible,
               event.keyCode == 53 {
                self.dismissIncrementalSearch()
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

        // Left padding between separator and code.
        // Top inset pushes first line below the unified toolbar (~52pt).
        textView.textContainerInset = NSSize(width: 8, height: 52)

        // Re-highlight newly visible text on scroll.
        NotificationCenter.default.addObserver(
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
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: theme.editorForeground
        ]
        SyntaxOracle.shared.baseFont = font   // clean base for fallback + multipliers

        // DIAGNOSTIC: Top inset 0 — let text underlap the toolbar for scroll-edge test.
        // Left inset provides padding between separator and code.
        textView.textContainerInset = NSSize(width: 8, height: 0)
        if let ruler = lineNumberGutter {
            ruler.textColor = theme.editorForeground.withAlphaComponent(0.50)
            ruler.font = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
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

        // ── Search bar follows theme when visible ──
        incrementalSearchBar?.updateTheme()

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

    /// Pushes the current highlighted document to the SwiftUI surface via
    /// `onDocumentChange`.
    private func notifyDocumentChange() {
        onDocumentChange?(highlightedDocument())
    }

    func newDocument() {
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
        let mode = GeneralSettings.shared.newFileMode
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
        notifyDocumentChange()

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
        notifyDocumentChange()
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
                notifyDocumentChange()
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
            notifyDocumentChange()
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

    /// Post status bar info via callback so MainWindowController can update the glass bar.
    private func updateStatusBar() {
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
        if incrementalSearchBar.isVisible {
            // Ctrl+S with bar visible:
            //   • If we have matches → navigate FORWARD
            //   • If no matches (just reopened with old text) → fire search from origin
            if searchMatches.isEmpty {
                incrementalSearchBar.fireSearchFromCurrent()
            } else {
                navigateSearch(forward: true)
            }
            return
        }

        let centerX = view.bounds.midX
        let barY: CGFloat = 52   // near bottom of editor — 16px margin + 36px bar height
        incrementalSearchBar.show(in: view, centerX: centerX, bottomY: barY)
        preSearchSelection = textView.selectedRange()
        searchOrigin = preSearchSelection?.location ?? 0
        incrementalSearchBar.onSearchChange = { [weak self] text, ignoreCase, wrap in
            self?.performSearch(text: text, ignoreCase: ignoreCase, wrapAround: wrap)
        }
        incrementalSearchBar.onNavigate = { [weak self] forward in
            self?.navigateSearch(forward: forward)
        }
        incrementalSearchBar.onConfirm = { [weak self] in
            // Enter → navigate forward, then dismiss (stay at match)
            self?.navigateSearch(forward: true)
            self?.dismissIncrementalSearch()
        }
        incrementalSearchBar.onDismiss = { [weak self] in
            self?.dismissSearchCleanup()
        }
    }

    func dismissIncrementalSearch() {
        guard incrementalSearchBar.isVisible else { return }
        incrementalSearchBar.hide()
    }

    /// Called from Edit → Find menu — navigates forward through search matches.
    @objc func searchNavigateForward() {
        if incrementalSearchBar.isVisible, !searchMatches.isEmpty {
            navigateSearch(forward: true)
        }
    }

    /// Clean up search state WITHOUT restoring cursor — user stays where they navigated.
    private func dismissSearchCleanup() {
        preSearchSelection = nil
        searchMatches = []
        currentSearchIndex = 0
        textView?.needsDisplay = true
        lineNumberGutter?.needsDisplay = true
        view.window?.makeFirstResponder(textView)
    }

    @objc func navigateSearch(forward: Bool) {
        guard !searchMatches.isEmpty else { return }
        if forward {
            currentSearchIndex = (currentSearchIndex + 1) % searchMatches.count
        } else {
            currentSearchIndex = (currentSearchIndex - 1 + searchMatches.count) % searchMatches.count
        }
        selectCurrentMatch()
    }

    private func performSearch(text: String, ignoreCase: Bool, wrapAround: Bool) {
        guard let storage = textStorage, storage.length > 0 else {
            searchMatches = []
            currentSearchIndex = 0
            incrementalSearchBar.updateMatch(current: 0, total: 0)
            return
        }

        guard !text.isEmpty else {
            searchMatches = []
            currentSearchIndex = 0
            incrementalSearchBar.updateMatch(current: 0, total: 0)
            return
        }

        let nsStr = storage.string as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)
        var opts: NSString.CompareOptions = []
        if ignoreCase { opts.insert(.caseInsensitive) }

        var matches: [NSRange] = []
        var searchRange = fullRange
        while true {
            let found = nsStr.range(of: text, options: opts, range: searchRange)
            if found.location == NSNotFound { break }
            matches.append(found)
            let nextLoc = found.location + found.length
            if nextLoc >= nsStr.length { break }
            searchRange = NSRange(location: nextLoc, length: nsStr.length - nextLoc)
        }
        searchMatches = matches

        if matches.isEmpty {
            currentSearchIndex = 0
            incrementalSearchBar.updateMatch(current: 0, total: 0)
            return
        }

        let idx = matches.firstIndex { $0.location >= searchOrigin } ?? 0
        currentSearchIndex = idx
        incrementalSearchBar.updateMatch(current: currentSearchIndex + 1, total: searchMatches.count)

        // Defer selection — setting it from within the search field's
        // textDidChange notification can cause display pass entanglement.
        let matchRange = matches[idx]
        DispatchQueue.main.async { [weak self] in
            guard let self, let tv = self.textView,
                  matchRange.location + matchRange.length <= self.textStorage.length else { return }
            tv.setSelectedRange(matchRange)
            tv.scrollRangeToVisible(matchRange)
        }
    }

    private func selectCurrentMatch() {
        guard !searchMatches.isEmpty,
              currentSearchIndex < searchMatches.count else { return }
        let matchRange = searchMatches[currentSearchIndex]
        guard matchRange.location + matchRange.length <= textStorage.length else { return }
        let r = matchRange
        DispatchQueue.main.async { [weak self] in
            guard let self, let tv = self.textView,
                  r.location + r.length <= self.textStorage.length else { return }
            tv.setSelectedRange(r)
            tv.scrollRangeToVisible(r)
        }
        incrementalSearchBar.updateMatch(current: currentSearchIndex + 1, total: searchMatches.count)
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

        let fullRange = NSRange(location: 0, length: textStorage.length)
        isHighlighting = true
        (layoutManager as? HighlightingLayoutManager)?.isApplyingHighlighting = true
        defer {
            isHighlighting = false
            (layoutManager as? HighlightingLayoutManager)?.isApplyingHighlighting = false
        }
        SyntaxOracle.shared.applyHighlighting(to: textStorage, range: fullRange, font: nil)

        // Restore cursor to the position computed in shouldChangeTextIn.
        // Attribute changes (setAttributes/addAttributes) perturb the insertion
        // point's pixel position because bold/heading fonts have different glyph
        // widths in proportional text. The character index should be stable, but
        // processEditing can drift it by ±1. Pin it back.
        if let pos = expectedPostEditCursor, pos <= textStorage.length {
            textView.setSelectedRange(NSRange(location: pos, length: 0))
        }
        expectedPostEditCursor = nil

        notifyDocumentChange()

        clearGhostSuggestion()

        foldDetectionDebounce?.invalidate()
        foldDetectionDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.detectFolds()
        }
    }

    /// Strip rich formatting on paste — we manage all attributes ourselves.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Capture where the cursor WILL be after this edit commits.
        let len = (replacementString as NSString?)?.length ?? 0
        expectedPostEditCursor = affectedCharRange.location + len

        guard !isHandlingPaste,
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