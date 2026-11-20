import SwiftUI
import AppKit
import Combine
import CSafeLayout

// MARK: - Document model

/// Observable bridge feeding the SwiftUI TextKit 2 surface the editor's
/// highlighted document. `EditorViewController` remains the controller/model —
/// it owns `textStorage` (the already-highlighted attributed string) and pushes
/// a snapshot here whenever the document changes. SwiftUI owns rendering + scroll.
final class EditorDocumentModel: ObservableObject {
    @Published var attributedString: NSAttributedString = NSAttributedString()
    @Published var revision: Int = 0
    /// Document shape, updated on every edit without copying the attributed
    /// string. These two numbers drive the scroll extent + gutter width, so a
    /// keystroke never forces a full-document copy, split, or layout.
    @Published var lineCount: Int = 1
    @Published var maxLineWidth: Int = 0
}

// MARK: - Gutter style

/// Visual + geometric config for the line-number gutter, resolved from the
/// active theme. The gutter is drawn by `GutterRenderView`, a pinned sibling to
/// the horizontal text scroller, so line numbers stay put during horizontal scroll.
struct EditorGutterStyle {
    var activeLine: Int = 1
    /// 1-based inclusive range of lines covered by the current multi-line
    /// selection (nil when there is no selection). The gutter paints these
    /// line numbers with the selection background instead of the caret band.
    var selectedLineRange: ClosedRange<Int>? = nil
    var width: CGFloat = 0
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// Height of one *code* line — the gutter highlight must never be shorter
    /// than this (and line origins are derived from it so numbers stay locked
    /// to the non-wrapping text view).
    var lineHeight: CGFloat = 17
    var textColor: NSColor = .tertiaryLabelColor
    var separatorColor: NSColor?
    /// Tint for the glass gutter surface — the sidebar surface color, applied at
    /// reduced opacity over a frosted material by `TextKit2ScrollSurface`.
    var backgroundColor: NSColor? = nil
    /// Band behind the caret line when no selection is active.
    var lineHighlightColor: NSColor = NSColor(white: 0.12, alpha: 1.0)
    /// Foreground for the caret line number when no selection is active —
    /// brighter than the dim ruler text, but distinct from the selection
    /// foreground so the caret line never reads as "selected".
    var activeLineForeground: NSColor = .labelColor
    var selectionBackground: NSColor = .controlAccentColor
    var selectionForeground: NSColor = .labelColor
    /// 1px top/bottom borders around the selected region (TextMate gutter style).
    var selectionBorder: NSColor = NSColor(red: 0.00, green: 0.22, blue: 0.44, alpha: 0.8)
    /// 1px top/bottom borders on the caret line band — mirrors the code band's
    /// `lineHighlightBorder` so the gutter and code edges read as one surface.
    var lineHighlightBorder: NSColor = NSColor(white: 0.30, alpha: 0.5)
    /// Extra width on the left edge — extends the gutter toward the floating
    /// sidebar sheet so the active-line highlight connects to the file browser.
    var leftOverhang: CGFloat = SidebarSheetGeometry.trailing
}

extension EditorGutterStyle {
    /// Line numbers render slightly smaller than the code face — one shared
    /// scale keeps the SwiftUI gutter and the AppKit ruler identical.
    static let rulerFontScale: CGFloat = 0.8

    /// Left breathing room before the widest line number. The number column is
    /// right-aligned against the fold gutter, so widening this only grows the
    /// column's left side — the numbers never kiss the sidebar edge.
    static let numberLeftPadding: CGFloat = 12

    /// Resolve the gutter face for a code font. Tracks the per-filetype
    /// `.aether-properties` font size (`SyntaxOracle.shared.baseFont`) so the
    /// numbers shrink/grow with the code instead of snapping to a fixed size.
    /// Themes may pin an absolute size via `pinnedSize`.
    static func rulerFont(for codeFont: NSFont, pinnedSize: CGFloat? = nil) -> NSFont {
        let size = pinnedSize ?? (codeFont.pointSize * rulerFontScale)
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Exact baseline-to-baseline pitch for one code line. `defaultLineHeight(for:)`
    /// includes the font's `leading`, but real layout uses `ceil(ascender − descender)
    /// + lineSpacing`. For faces like Monaco the two differ by ~1pt/line — an
    /// arithmetic guess therefore drifts one line-height per hundred lines. Measure
    /// the actual fragment height instead of guessing it.
    static func measuredLineHeight(for font: NSFont, lineSpacing: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributed = NSAttributedString(
            string: "A\nB\nC",
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100_000, height: 100_000))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else {
            return layout.defaultLineHeight(for: font) + lineSpacing
        }
        return layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    }
}

// MARK: - TextKit 2 measurement

/// Measures a document's full layout extent using TextKit 2, independently of
/// any view. Used to size the SwiftUI `ScrollView` content so SwiftUI owns the
/// scrolling and the native scroll-edge effect can engage.
enum TextKit2Layout {
    /// Files with more lines than this skip full-document layout and use a
    /// linear-time estimate. `ensureLayout(for: documentRange)` on a huge
    /// attributed string is what freezes the editor on open; the estimate has
    /// no layout cost and keeps vertical extent + horizontal scroll sane.
    static let largeFileLineThreshold = 20_000

    static func measure(_ attributedString: NSAttributedString,
                        containerWidth: CGFloat,
                        lineHeight: CGFloat = 17) -> CGSize {
        let text = attributedString.string as NSString
        // The code editor never wraps (`containerWidth == 0`) and uses a uniform
        // monospaced face, so the full TextKit 2 `ensureLayout(for:)` below is
        // pure overhead — it is what froze the editor on every keystroke for
        // mid-sized files. The arithmetic estimate is exact for a non-wrapping
        // monospaced document and has no glyph-layout cost.
        if containerWidth <= 0 || Self.lineCount(text) > largeFileLineThreshold {
            return estimate(attributedString, lineHeight: lineHeight)
        }

        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        storage.addTextLayoutManager(layout)

        let container = NSTextContainer(size: CGSize(width: containerWidth, height: 0))
        container.widthTracksTextView = false
        layout.textContainer = container

        storage.performEditingTransaction {
            storage.textStorage?.setAttributedString(attributedString)
        }

        let range = storage.documentRange
        layout.ensureLayout(for: range)

        var union = CGRect.zero
        layout.enumerateTextLayoutFragments(from: range.location,
                                            options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            union = union.union(fragment.layoutFragmentFrame)
            return true
        }
        return union.size
    }

    /// Linear-time measurement: count lines for height, scan for the widest line
    /// for horizontal scroll extent. No layout manager involved.
    private static func estimate(_ attributedString: NSAttributedString,
                                 lineHeight: CGFloat) -> CGSize {
        let text = attributedString.string as NSString
        let lines = lineCount(text)
        let widest = maxLineLength(text)
        var charWidth = max(lineHeight * 0.6, 1)
        if text.length > 0,
           let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
            if advance > 0 { charWidth = advance }
        }
        return CGSize(width: CGFloat(widest) * charWidth,
                      height: CGFloat(max(lines, 1)) * lineHeight)
    }

    private static func lineCount(_ text: NSString) -> Int {
        guard text.length > 0 else { return 0 }
        var count = 1
        var i = 0
        while i < text.length {
            if text.character(at: i) == 0x0A { count += 1 }
            i += 1
        }
        return count
    }

    private static func maxLineLength(_ text: NSString) -> Int {
        var maxLen = 0
        var lineStart = 0
        var i = 0
        while i <= text.length {
            if i == text.length || text.character(at: i) == 0x0A {
                maxLen = max(maxLen, i - lineStart)
                lineStart = i + 1
            }
            i += 1
        }
        return maxLen
    }
}

// MARK: - TextKit 1 editable view (NOT an NSScrollView)

/// Editable text view using TextKit 1 (NSTextStorage → NSLayoutManager → NSTextContainer → NSTextView).
/// This matches EditorViewController's architecture and allows sharing the same textStorage.
/// Designed to be embedded in a SwiftUI `ScrollView` so SwiftUI owns scrolling
/// and the native `.scrollEdgeEffectStyle` blur applies at the top edge.
final class TextKit2EditorView: NSView {
    private var textView: NSTextView!
    private var layoutManager: NSLayoutManager!
    private var textContainer: NSTextContainer!

    /// The shared text storage from EditorViewController (highlighting happens there)
    weak var sharedTextStorage: NSTextStorage? {
        didSet {
            if let storage = sharedTextStorage, let lm = layoutManager {
                // Remove from old storage if needed
                if let oldStorage = lm.textStorage {
                    oldStorage.removeLayoutManager(lm)
                }
                // Add to new storage
                storage.addLayoutManager(lm)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // TextKit 1 pipeline (matches EditorViewController)
        layoutManager = HighlightingLayoutManager()

        // TextContainer: no width limit for horizontal scroll
        textContainer = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        // Keep fragment padding zero; the view inset below supplies breathing
        // room, and HighlightingLayoutManager paints selection across that inset.
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        // NSTextView using TextKit 1
        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        // Vertical breathing room is owned by TextKit2ScrollSurface so the
        // editable and passive render paths share identical geometry. Horizontal
        // inset belongs to the text view, not a SwiftUI spacer, so backgrounds
        // can connect to the gutter while glyphs remain comfortably inset.
        textView.textContainerInset = NSSize(width: EditorChromeMetrics.codeLeadingPadding, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true

        // Disable smart quotes/dashes (code editor)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.autoresizingMask = []
        addSubview(textView)
    }

    override var isFlipped: Bool { true }

    func adopt(_ editor: NSTextView) {
        guard textView !== editor else { return }
        textView.removeFromSuperview()
        editor.enclosingScrollView?.documentView = nil
        textView = editor
        layoutManager = editor.layoutManager
        textContainer = editor.textContainer
        editor.removeFromSuperview()
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: EditorChromeMetrics.codeLeadingPadding, height: 0)
        textContainer.lineFragmentPadding = 0
        editor.autoresizingMask = []
        editor.isHorizontallyResizable = true
        editor.isEditable = true
        editor.allowsUndo = true
        textContainer.widthTracksTextView = false
        addSubview(editor)
        needsLayout = true
    }

    deinit {
        // When a tab is switched away, SwiftUI destroys this surface (its `.id`
        // is the tab's identity). Detach the adopted NSTextView so it does not
        // retain a dangling superview; `EditorViewController` still owns it and
        // re-adopts it into a fresh surface when the tab returns.
        textView?.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        textView.frame = bounds

        // Update textContainer size to match view
        textContainer.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    /// Make textView first responder when clicked
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    /// Expose textView for first responder handling
    var editorTextView: NSTextView { textView }
}

// MARK: - Legacy render view (kept for reference, unused)

/// Draws an attributed document via `NSTextLayoutManager` + `NSTextContentStorage`.
/// Passive content sized to the full document extent and scrolled by a SwiftUI
/// `ScrollView` — that ownership split is the entire point: SwiftUI owns the
/// scroll, so `.scrollEdgeEffectStyle` applies natively. This view renders text
/// only; the line-number gutter lives in a pinned sibling (`GutterRenderView`).
final class TextKit2RenderView: NSView {
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private var fragments: [NSTextLayoutFragment] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        contentStorage.addTextLayoutManager(layoutManager)

        // Width 0 = no wrapping limit; lines extend to their natural width so
        // horizontal scrolling (and the trailing edge) has real content.
        let container = NSTextContainer(size: CGSize(width: 0, height: 0))
        container.widthTracksTextView = false
        layoutManager.textContainer = container
    }

    override var isFlipped: Bool { true }

    func setAttributedString(_ attributedString: NSAttributedString) {
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(attributedString)
        }
        layoutManager.invalidateLayout(for: contentStorage.documentRange)

        let range = contentStorage.documentRange
        layoutManager.ensureLayout(for: range)

        fragments.removeAll()
        layoutManager.enumerateTextLayoutFragments(from: range.location,
                                                   options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            self.fragments.append(fragment)
            return true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            if frame.intersects(dirtyRect) {
                fragment.draw(at: frame.origin, in: context)
            }
        }
    }
}

// MARK: - Gutter render view (pinned horizontally)

/// Draws only the line-number gutter. Hosted as a fixed-width sibling to the
/// horizontal text scroller, so it scrolls vertically with the document (line
/// numbers stay aligned with their lines) but never moves sideways.
final class GutterRenderView: NSView {
    private var cachedStringIdentity: ObjectIdentifier? = nil
    private var cachedSourceLength: Int = -1
    private var lineCount: Int = 0
    /// UTF-16 offsets of the first character of each line, in document order
    /// (`[0, offsetOfLine2, …]`, one entry per line). Built once per document
    /// change so a character offset maps to a line number in O(log n) — the
    /// layout manager gives us exact per-line fragment rects, but not the line's
    /// ordinal.
    private var lineStartOffsets: [Int] = []

    /// Line-number gutter configuration (width + colors), resolved from the theme.
    var gutter: EditorGutterStyle = EditorGutterStyle() {
        didSet { needsDisplay = true }
    }

    /// Live layout manager of the adopted editor. Its per-line fragment rects are
    /// the source of truth for each number's origin, so a taller line (emoji, a
    /// larger inline face) keeps its number locked instead of drifting.
    weak var sourceLayoutManager: NSLayoutManager? {
        didSet {
            rewireSelectionObserver()
            needsDisplay = true
        }
    }

    /// Shared fold state + detected regions. `ObservableObject`: the gutter
    /// repaints whenever regions are re-detected or a region toggles.
    weak var foldState: FoldState? {
        didSet {
            guard foldState !== oldValue else { return }
            foldCancellable = foldState?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.needsDisplay = true }
            }
            needsDisplay = true
        }
    }
    /// Invoked when a fold triangle is clicked; the owner toggles the region.
    var onFoldToggle: ((FoldRegion) -> Void)?
    private var foldCancellable: AnyCancellable?

    private let foldGutterWidth: CGFloat = 14
    private let numberGap: CGFloat = 12
    private let triangleSize: CGFloat = 5
    private var foldToggleColor: NSColor { gutter.textColor.withAlphaComponent(0.5) }
    /// Observer for the adopted text view's selection changes (see
    /// `rewireSelectionObserver()`). Held so it can be removed on deinit.
    private var selectionObserver: NSObjectProtocol? = nil
    /// Observer for the live storage's `didProcessEditing` — the only signal
    /// that knows whether an edit changed the *line structure* (inserted or
    /// removed a newline). Held so it can be removed on deinit.
    private var storageObserver: NSObjectProtocol? = nil
    /// Set when the line structure may have changed since the last index build.
    /// Rebuilt lazily on the next paint; typing on one line never rebuilds.
    private var lineStructureDirty = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = storageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func commonInit() {
        // Line origins are read from the live editor layout manager in `draw`;
        // no secondary TextKit pipeline is owned here.
    }

    /// Directly repaint the gutter on every selection change of the adopted text
    /// view. `NSTextView` posts `didChangeSelectionNotification` synchronously
    /// during a mouse drag; observing it here (rather than through SwiftUI's
    /// `.onReceive` → `@State` → `updateNSView` round-trip, which the event
    /// tracking loop defers until mouse-up) is what keeps the line-number column
    /// selection glued to the cursor in real time.
    private func rewireSelectionObserver() {
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionObserver = nil
        }
        if let observer = storageObserver {
            NotificationCenter.default.removeObserver(observer)
            storageObserver = nil
        }
        guard let lm = sourceLayoutManager else { return }
        if let tv = lm.textContainers.first?.textView {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: tv,
                queue: nil
            ) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
        guard let storage = lm.textStorage else { return }
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] _ in
            self?.noteStorageEdited()
        }
    }

    /// Maintains the line-start index incrementally on every character edit —
    /// O(edit size), never O(document). Offsets after the edit shift by the
    /// length delta even when no newline is involved (typing on one line moves
    /// every later line's start), which is exactly why the old rebuild-once
    /// approach let the numbers drift away from the code while editing.
    private func noteStorageEdited() {
        guard let storage = sourceLayoutManager?.textStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let delta = storage.changeInLength
        guard edited.length > 0, !lineStartOffsets.isEmpty else {
            // A pure deletion shrinking the document to nothing, or a first edit
            // into an empty index — fall back to a full rebuild on the next paint.
            lineStructureDirty = true
            return
        }
        let text = storage.string as NSString
        // The prefix before `edited.location` is identical in old and new text,
        // so binary-searching the OLD index with this coordinate is exact.
        let idx = lineNumber(forUTF16Offset: edited.location)
        guard idx < lineStartOffsets.count else {
            lineStructureDirty = true
            return
        }
        var rebuilt: [Int] = [lineStartOffsets[idx]]
        var cursor = edited.location
        let editEnd = edited.location + edited.length
        while cursor < editEnd {
            if text.character(at: cursor) == 0x0A { rebuilt.append(cursor + 1) }
            cursor += 1
        }
        // The old span's last consumed line — derived from the OLD index, not
        // the new text: the removed text is gone, but every line it consumed is
        // one whose start lay in (editPoint, editPoint + removedLength]. The
        // binary search over the still-old index bounds that span exactly.
        let removedLength = max(0, edited.length - delta)
        let oldLast = removedLength > 0
            ? lineNumber(forUTF16Offset: edited.location + removedLength)
            : idx
        lineStartOffsets = Array(lineStartOffsets[..<idx]) + rebuilt
            + lineStartOffsets[(oldLast + 1)...].map { $0 + delta }
        lineCount = lineStartOffsets.count
    }

    override var isFlipped: Bool { true }

    func setAttributedString(_ attributedString: NSAttributedString) {
        // Prefer the live layout manager's text storage (the exact text the
        // fragments are laid out from) so line starts never lag the SwiftUI
        // snapshot.
        let liveString = sourceLayoutManager?.textStorage?.string as NSString?
        let source = liveString ?? (attributedString.string as NSString)
        let identity = ObjectIdentifier(attributedString)
        if identity != cachedStringIdentity {
            // A fresh snapshot object = the document was replaced (load/new).
            cachedStringIdentity = identity
            lineStructureDirty = true
        }
        refreshLineIndexIfNeeded(source: source)
        needsDisplay = true
    }

    /// Rebuilds `lineStartOffsets` + `lineCount` when the document was replaced
    /// or an edit changed the line structure — never on scroll/selection changes
    /// and never on single-line typing, which is what made the gutter re-walk
    /// the whole document per keystroke before.
    private func refreshLineIndexIfNeeded(source: NSString? = nil) {
        let liveString = source ?? (sourceLayoutManager?.textStorage?.string as NSString?)
        guard let text = liveString, lineStructureDirty else { return }
        lineStructureDirty = false
        cachedSourceLength = text.length
        lineCount = text.length > 0 ? 1 : 0
        lineStartOffsets = []
        if text.length > 0 {
            lineStartOffsets.append(0)
            var i = 0
            while i < text.length {
                if text.character(at: i) == 0x0A {
                    lineCount += 1
                    lineStartOffsets.append(i + 1)
                }
                i += 1
            }
        }
    }

    /// Uniform per-line pitch — the seed/fallback only. The primary gutter path
    /// reads exact fragment rects from the live layout manager; this value backs
    /// the arithmetic fallback (passive render without an adopted editor) and the
    /// scroll-extent estimate, so it stays a coarse average even when an emoji or
    /// larger inline face makes individual lines taller than their neighbours.
    private var liveLineHeight: CGFloat {
        if let lm = sourceLayoutManager, lm.numberOfGlyphs > 0 {
            let height = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
            if height > 0 { return height }
        }
        return gutter.lineHeight
    }

    /// Line rect for a 1-based line number on the arithmetic grid — fallback only,
    /// used when there is no adopted layout manager to measure against.
    private func rect(forLine number: Int) -> CGRect {
        let lineHeight = liveLineHeight
        return CGRect(x: 0, y: CGFloat(number - 1) * lineHeight,
                       width: bounds.width, height: lineHeight)
    }

    /// 0-based line index for a UTF-16 character offset (binary search).
    private func lineNumber(forUTF16Offset offset: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : 0
    }

    /// Visible `(lineNumber, fragmentRect)` pairs intersecting `dirtyRect`, read
    /// straight from the live layout manager. Only the visible lines are visited;
    /// each number lands on its own fragment's origin so variable line heights can
    /// never desynchronise the gutter from the code.
    private func visibleNumberLines(in dirtyRect: NSRect) -> [(Int, CGRect, Bool)] {
        guard let lm = sourceLayoutManager, lm.numberOfGlyphs > 0,
              let tc = lm.textContainers.first,
              dirtyRect.width > 0, dirtyRect.height > 0 else {
            return arithmeticNumberLines(in: dirtyRect)
        }
        let glyphRange = lm.glyphRange(forBoundingRect: dirtyRect, in: tc)
        guard glyphRange.length > 0 else { return [] }
        var lines: [(Int, CGRect, Bool)] = []
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragGlyphRange, _ in
            let charRange = lm.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let lineIndex = self.lineNumber(forUTF16Offset: charRange.location)
            // A fragment that does not begin at its logical line's first character
            // is a soft-wrapped continuation — same line number, extra visual row.
            let isContinuation = lineIndex < self.lineStartOffsets.count
                && charRange.location != self.lineStartOffsets[lineIndex]
            // Measured placement: the layout manager's own fragment rect is the
            // source of truth. A taller line (emoji, larger inline face) keeps its
            // number locked to its glyphs instead of drifting on a uniform grid.
            let frame = CGRect(x: 0, y: rect.minY, width: self.bounds.width, height: rect.height)
            lines.append((lineIndex + 1, frame, isContinuation))
        }
        return lines
    }

    /// Uniform-spacing fallback for the passive (non-editable) render path.
    private func arithmeticNumberLines(in dirtyRect: NSRect) -> [(Int, CGRect, Bool)] {
        let lineHeight = liveLineHeight
        guard lineHeight > 0, lineCount > 0 else { return [] }
        let first = max(1, Int(floor(dirtyRect.minY / lineHeight)) + 1)
        let last = min(lineCount, Int(ceil(dirtyRect.maxY / lineHeight)))
        guard first <= last else { return [] }
        // Uniform-pitch fallback has no soft-wrap context: every row is a real line.
        return (first...last).map { ($0, rect(forLine: $0), false) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The storage notification can mark the line structure dirty between
        // SwiftUI passes (selection-only repaints, programmatic edits) — rebuild
        // before reading the index so every paint sees the current text shape.
        refreshLineIndexIfNeeded()
        guard gutter.width > 0, lineCount > 0 else { return }

        // The gutter background is a translucent glass surface applied by
        // `TextKit2ScrollSurface` (material + tint). This view stays transparent
        // so the frosted material behind it shows through as blur, not flat fill.
        // Numbers, divider and the selection/current-line bands all span the
        // gutter's own width (left overhang included).
        let contentWidth = bounds.width
        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutter.font,
            .foregroundColor: gutter.textColor,
        ]
        // Resolve the live caret + selection straight from the adopted editor so
        // the gutter tracks a drag in real time — no SwiftUI round-trip, which is
        // why a dragged selection previously froze until mouse-up.
        var activeLine = gutter.activeLine
        var selectedLines = gutter.selectedLineRange
        if let tv = sourceLayoutManager?.textContainers.first?.textView {
            let len = sourceLayoutManager?.textStorage?.length ?? 0
            let sel = tv.selectedRange()
            if len > 0 {
                activeLine = lineNumber(forUTF16Offset: min(sel.location, max(len - 1, 0))) + 1
                if sel.length > 0, sel.location < len {
                    let start = lineNumber(forUTF16Offset: sel.location) + 1
                    let endIdx = max(sel.location, min(NSMaxRange(sel) - 1, max(len - 1, 0)))
                    let end = lineNumber(forUTF16Offset: endIdx) + 1
                    selectedLines = start...end
                } else {
                    selectedLines = nil
                }
            } else {
                selectedLines = nil
            }
        }
        let hasSelection = selectedLines != nil

        // ── Viewport-only drawing ──
        // Exact per-line fragment rects from the live layout manager: only the
        // visible lines are visited, and each number lands on its own line even
        // when an emoji or a larger inline face changes that line's height.
        let visibleLines = visibleNumberLines(in: dirtyRect)
        guard !visibleLines.isEmpty else { return }
        let firstVisible = visibleLines.first!.0
        let lastVisible = visibleLines.last!.0

        // ── Pass 1: selection band (multi-line selection) ──
        // TextMate convention: full-width background over every selected line,
        // with a single 1px border only on the run's top and bottom edges.
        if hasSelection, let selectedLines {
            let bandFirst = max(selectedLines.lowerBound, firstVisible)
            let bandLast = min(selectedLines.upperBound, lastVisible)
            if bandFirst <= bandLast,
               let top = visibleLines.first(where: { $0.0 == bandFirst })?.1.minY,
               let bottom = visibleLines.last(where: { $0.0 == bandLast })?.1.maxY {
                gutter.selectionBackground.setFill()
                NSRect(x: 0, y: top, width: contentWidth, height: bottom - top).fill()
                // Edge borders only where the run meets an unselected line.
                gutter.selectionBorder.setFill()
                if bandFirst == selectedLines.lowerBound {
                    NSRect(x: 0, y: top, width: contentWidth, height: 1).fill()
                }
                if bandLast == selectedLines.upperBound {
                    NSRect(x: 0, y: bottom - 1, width: contentWidth, height: 1).fill()
                }
            }
        }

        // ── Pass 2: line numbers + caret band ──
        for (number, frame, isContinuation) in visibleLines {
            // Soft-wrapped continuation rows keep their line number but show a
            // middot instead — TextMate's convention for "this is still line N".
            let text = (isContinuation ? "·" : "\(number)") as NSString
            let size = text.size(withAttributes: attrs)
            // Right-align numbers (and continuation middots), leaving the fold
            // gutter + gap to the separator.
            let x = contentWidth - foldGutterWidth - numberGap - size.width
            let y = frame.origin.y + (frame.height - size.height) / 2
            var numberAttributes = attrs
            let isSelected = selectedLines?.contains(number) ?? false
            if isSelected {
                numberAttributes[.foregroundColor] = gutter.selectionForeground
            } else if number == activeLine && !hasSelection {
                // Caret band only when nothing is selected — otherwise the
                // selection band is the highlight and a second band is noise.
                // Matches the code band's 0.40 alpha so both halves of the
                // current-line gutter read as one continuous surface.
                gutter.lineHighlightColor.withAlphaComponent(0.40).setFill()
                NSRect(x: 0, y: frame.minY, width: contentWidth, height: frame.height).fill()
                gutter.lineHighlightBorder.setFill()
                NSRect(x: 0, y: frame.minY, width: contentWidth, height: 1).fill()
                NSRect(x: 0, y: frame.maxY - 1, width: contentWidth, height: 1).fill()
                numberAttributes[.foregroundColor] = gutter.activeLineForeground
            }
            if isContinuation {
                // The band above still draws (same logical line), but the middot
                // stays the dim ruler color — it is a marker, not a line number.
                numberAttributes[.foregroundColor] = gutter.textColor
            }
            text.draw(at: NSPoint(x: x, y: y), withAttributes: numberAttributes)
        }

        // ── Pass 3: fold toggles ──
        // Collapsed markers come from `foldedRegions` (so a folded block keeps its
        // triangle for unfolding even after its body is hidden), expanded ones from
        // the re-detected `regions`. Each lands on its own line's measured origin.
        let foldRegions = foldRegionsToDraw()
        if !foldRegions.isEmpty {
            var frameByLine: [Int: CGRect] = [:]
            for (number, frame, isContinuation) in visibleLines where !isContinuation {
                frameByLine[number] = frame
            }
            for (region, collapsed) in foldRegions {
                guard let frame = frameByLine[region.startLine + 1] else { continue }
                drawFoldTriangle(centerX: foldGutterWidth / 2,
                                 centerY: frame.midY,
                                 collapsed: collapsed)
            }
        }

    }

    // MARK: - Fold interaction

    /// Fold regions to render, deduplicated by start line. Folded regions win
    /// over re-detected ones so a collapsed block keeps a single, collapsed marker.
    private func foldRegionsToDraw() -> [(region: FoldRegion, collapsed: Bool)] {
        guard let foldState else { return [] }
        var byStartLine: [Int: FoldRegion] = [:]
        var collapsedStarts = Set<Int>()
        for region in foldState.foldedRegions {
            byStartLine[region.startLine] = region
            collapsedStarts.insert(region.startLine)
        }
        for region in foldState.regions where byStartLine[region.startLine] == nil {
            byStartLine[region.startLine] = region
        }
        return byStartLine.values
            .sorted { $0.startLine < $1.startLine }
            .map { (region: $0, collapsed: collapsedStarts.contains($0.startLine)) }
    }

    private func drawFoldTriangle(centerX: CGFloat, centerY: CGFloat, collapsed: Bool) {
        let s = triangleSize * 0.5
        let path = NSBezierPath()
        if collapsed {
            // Right-pointing triangle: collapsed.
            path.move(to: NSPoint(x: centerX - s * 0.4, y: centerY - s))
            path.line(to: NSPoint(x: centerX + s * 0.8, y: centerY))
            path.line(to: NSPoint(x: centerX - s * 0.4, y: centerY + s))
        } else {
            // Down-pointing triangle: expanded.
            path.move(to: NSPoint(x: centerX - s, y: centerY + s * 0.5))
            path.line(to: NSPoint(x: centerX,     y: centerY - s * 0.8))
            path.line(to: NSPoint(x: centerX + s, y: centerY + s * 0.5))
        }
        path.close()
        foldToggleColor.setFill()
        path.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the fold gutter is interactive; the number column passes clicks
        // through to the document underneath.
        return point.x < foldGutterWidth + 4 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < foldGutterWidth + 4, foldState != nil else { return }
        // Resolve the clicked line from its measured fragment rect, then match a
        // fold region whose start line is that line.
        let probeRect = NSRect(x: 0, y: point.y - 8, width: bounds.width, height: 16)
        let regions = foldRegionsToDraw()
        for (number, frame, isContinuation) in visibleNumberLines(in: probeRect) {
            guard !isContinuation, point.y >= frame.minY, point.y < frame.maxY else { continue }
            let startLine = number - 1
            if let match = regions.first(where: { $0.region.startLine == startLine }) {
                onFoldToggle?(match.region)
            }
            return
        }
    }
}

// MARK: - NSViewRepresentable bridges

struct TextKit2RenderRepresentable: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> TextKit2RenderView {
        let view = TextKit2RenderView(frame: .zero)
        view.setAttributedString(attributedString)
        return view
    }

    func updateNSView(_ nsView: TextKit2RenderView, context: Context) {
        nsView.setAttributedString(attributedString)
    }
}

/// Editable TextKit 2 editor view — uses shared textStorage for highlight sync
struct TextKit2EditorRepresentable: NSViewRepresentable {
    let attributedString: NSAttributedString
    let sharedTextStorage: NSTextStorage?
    var existingEditor: NSTextView? = nil

    func makeNSView(context: Context) -> TextKit2EditorView {
        let view = TextKit2EditorView(frame: .zero)
        if let existingEditor {
            view.adopt(existingEditor)
            return view
        }
        view.sharedTextStorage = sharedTextStorage
        // Initial render
        if sharedTextStorage == nil {
            // Fallback: render without shared storage
        }
        return view
    }

    func updateNSView(_ nsView: TextKit2EditorView, context: Context) {
        if let existingEditor {
            nsView.adopt(existingEditor)
            return
        }
        // Sync textStorage if provided
        if let storage = sharedTextStorage {
            nsView.sharedTextStorage = storage
        }
    }

    /// Coordinator to handle first responder
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var windowObserver: NSObjectProtocol?

        deinit {
            if let obs = windowObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }
}

struct GutterRenderRepresentable: NSViewRepresentable {
    let attributedString: NSAttributedString
    let gutter: EditorGutterStyle
    var sourceLayoutManager: NSLayoutManager? = nil
    var foldState: FoldState? = nil
    var onFoldToggle: ((FoldRegion) -> Void)? = nil

    func makeNSView(context: Context) -> GutterRenderView {
        let view = GutterRenderView(frame: .zero)
        view.gutter = gutter
        view.sourceLayoutManager = sourceLayoutManager
        view.foldState = foldState
        view.onFoldToggle = onFoldToggle
        view.setAttributedString(attributedString)
        return view
    }

    func updateNSView(_ nsView: GutterRenderView, context: Context) {
        nsView.gutter = gutter
        nsView.sourceLayoutManager = sourceLayoutManager
        nsView.foldState = foldState
        nsView.onFoldToggle = onFoldToggle
        nsView.setAttributedString(attributedString)
    }
}

// MARK: - SwiftUI-owned scroll surface

/// The editor document, scrolled by SwiftUI. A vertical `ScrollView` owns the
/// top scroll-edge blur for both the pinned gutter and the text; the text sits in
/// a nested horizontal `ScrollView` so horizontal scrolling never moves the gutter.
/// When sharedTextStorage is provided, the editor is editable and syncs with EditorViewController.
struct CodeScrollHeader: View {
    let title: String
    let symbol: String
    var leading: CGFloat = 16
    var trailing: CGFloat = 16
    var height: CGFloat = EditorChromeMetrics.titleBarBand

    var body: some View {
        (Text(Image(systemName: symbol)) + Text("  " + title))
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(height: EditorChromeMetrics.titleBarBand)
        .frame(height: height, alignment: .top)
    }
}

struct TextKit2ScrollSurface: View {
    let attributedString: NSAttributedString
    let backgroundColor: Color
    let gutter: EditorGutterStyle
    /// Resolved opacity for the fixed line-number column surface. Kept as a
    /// separate value (not read from `gutter.backgroundColor`) so the
    /// `rulerBackgroundOpacity` override in ThemeSettings reaches the main gutter —
    /// the same resolution the sidebar sheet + status strip already honour.
    let gutterBackgroundOpacity: CGFloat
    let leadingChromeWidth: CGFloat
    let trailingChromeWidth: CGFloat
    /// Chrome rows (tab strip) sitting above the surface: their height is added
    /// to the top scroll inset so the first code line clears them at rest.
    let topChromeInset: CGFloat
    /// Shared text storage from EditorViewController — when provided, editor becomes editable
    var sharedTextStorage: NSTextStorage? = nil
    var existingEditor: NSTextView? = nil
    /// Fold state + detected regions, owned by `EditorViewController`. The gutter
    /// observes it and reports fold-triangle clicks through `onFoldToggle`.
    var foldState: FoldState? = nil
    var onFoldToggle: ((FoldRegion) -> Void)? = nil
    /// Incremental-search state owned by `EditorViewController`, rendered + scrolled here.
    @ObservedObject var searchModel: QuickSearchModel
    /// TextMate-style find & replace state, rendered + scrolled here too.
    @ObservedObject var findReplace: FindReplaceModel
    /// Wrap-column guide (vertical rule at a fixed character column).
    let showWrapColumn: Bool
    let wrapColumn: Int
    /// Lightweight document shape. The scroll extent is derived from these two
    /// numbers arithmetically — never from a full-document layout — so a keystroke
    /// or scroll frame is O(1) instead of O(document).
    let lineCount: Int
    let maxLineWidth: Int

    var topBarTitle: String = "Untitled"
    var topBarSymbol: String = "doc.text"

    @State private var scrollOffset: CGPoint = .zero
    @State private var activeLine = 1
    @State private var selectedLineRange: ClosedRange<Int>? = nil

    init(attributedString: NSAttributedString,
         backgroundColor: Color,
         gutter: EditorGutterStyle,
         leadingChromeWidth: CGFloat,
         trailingChromeWidth: CGFloat,
         topChromeInset: CGFloat = 0,
         gutterBackgroundOpacity: CGFloat = 0.55,
         sharedTextStorage: NSTextStorage? = nil,
         existingEditor: NSTextView? = nil,
         foldState: FoldState? = nil,
         onFoldToggle: ((FoldRegion) -> Void)? = nil,
         searchModel: QuickSearchModel,
         findReplace: FindReplaceModel,
         showWrapColumn: Bool = false,
         wrapColumn: Int = 80,
         lineCount: Int = 1,
         maxLineWidth: Int = 0) {
        self.attributedString = attributedString
        self.backgroundColor = backgroundColor
        self.gutter = gutter
        self.gutterBackgroundOpacity = gutterBackgroundOpacity
        self.leadingChromeWidth = leadingChromeWidth
        self.trailingChromeWidth = trailingChromeWidth
        self.topChromeInset = topChromeInset
        self.sharedTextStorage = sharedTextStorage
        self.existingEditor = existingEditor
        self.foldState = foldState
        self.onFoldToggle = onFoldToggle
        self.searchModel = searchModel
        self.findReplace = findReplace
        self.showWrapColumn = showWrapColumn
        self.wrapColumn = wrapColumn
        self.lineCount = lineCount
        self.maxLineWidth = maxLineWidth
    }

    /// Advance width of the document's monospaced face (the code editor uses one
    /// uniform font, so a single "0" measurement is exact for every line).
    private static func monospaceAdvance(for attributedString: NSAttributedString,
                                         fallbackLineHeight: CGFloat) -> CGFloat {
        if attributedString.length > 0,
           let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
            if advance > 0 { return advance }
        }
        return max(fallbackLineHeight * 0.6, 1)
    }

    /// The live per-line pitch from the adopted editor's layout manager — the same
    /// value `GutterRenderView` uses. Deriving the scroll extent + reveal targets
    /// from this (rather than the synthetic `gutter.lineHeight` seed) keeps the
    /// vertical extent exactly matched to the rendered text for any font/size/spacing.
    private static func liveLineHeight(_ lm: NSLayoutManager?, fallback: CGFloat) -> CGFloat {
        guard let lm = lm, lm.numberOfGlyphs > 0 else { return fallback }
        let height = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        return height > 0 ? height : fallback
    }

    var body: some View {
        GeometryReader { proxy in
            // Two visual code lines of breathing room below the floating title,
            // The safe-area bar itself reserves the title and tab-strip rows.
            // This is part of the scroll content, so it naturally disappears as
            // the user scrolls down instead of becoming another fixed toolbar.
            let topContentInset: CGFloat = EditorChromeMetrics.baseContentInset
                + (topChromeInset > 0 ? EditorChromeMetrics.tabBarContentClearance : 0)
            let topEdgeHeight = EditorChromeMetrics.scrollEdgeBarHeight(topInset: topChromeInset)
            // No bottom progressive blur: the horizontal scroller sits flush
            // against the status strip, so nothing reserves a ramp below the text.
            let bottomEdgeHeight: CGFloat = 0
            let visibleEditorWidth = max(proxy.size.width - leadingChromeWidth - trailingChromeWidth, 1)
            let viewportTextWidth = max(visibleEditorWidth - gutter.width, 1)
            // Live pitch from the adopted editor — keeps the scroll extent locked
            // to the real text height even when the seed drifts (font/size override).
            let effectiveLineHeight = Self.liveLineHeight(existingEditor?.layoutManager,
                                                          fallback: gutter.lineHeight)
            // Arithmetic extent from document shape — no layout, no copy.
            let charWidth = Self.monospaceAdvance(for: attributedString,
                                                  fallbackLineHeight: gutter.lineHeight)
            let docWidth = CGFloat(max(maxLineWidth, 1)) * charWidth
            let docHeight = CGFloat(max(lineCount, 1)) * effectiveLineHeight
            let textContentWidth = max(docWidth + 24, viewportTextWidth)
            let renderedHeight = max(docHeight, proxy.size.height - topContentInset - topEdgeHeight - bottomEdgeHeight)
            // TextMate-style "scroll past end": reserve enough trailing room
            // that the final line can ride up to just *under* the top safe-area
            // bar — its top lands one bar-height below the window's top edge
            // (`topEdgeHeight`) instead of hugging the very top and bleeding
            // into the titlebar's blur zone.
            let bottomOverscroll = max(0, proxy.size.height - topEdgeHeight
                                       - bottomEdgeHeight - effectiveLineHeight)
            // Reach toward the floating sidebar sheet only when it is present.
            let leftOverhang: CGFloat = leadingChromeWidth > 0 ? gutter.leftOverhang : 0
            let numbersOnlyGutter = EditorGutterStyle(
                activeLine: activeLine,
                selectedLineRange: selectedLineRange,
                width: gutter.width,
                font: gutter.font,
                lineHeight: gutter.lineHeight,
                textColor: gutter.textColor,
                separatorColor: gutter.separatorColor,
                backgroundColor: nil,
                lineHighlightColor: gutter.lineHighlightColor,
                selectionBackground: gutter.selectionBackground,
                selectionForeground: gutter.selectionForeground,
                selectionBorder: gutter.selectionBorder,
                lineHighlightBorder: gutter.lineHighlightBorder,
                leftOverhang: leftOverhang
            )

            // Content-space center of the current match, taken from the rect the
            // model measured for this very jump — never from a line estimate.
            // A line number times the line height drifts the moment wrapping or
            // folding breaks the 1:1 ratio, which is what made a reveal land at a
            // near-random offset. No rect, no reveal: an unmeasured hit (text view
            // not adopted yet, or the document changed under the scan) is simply
            // not scrolled to.
            let highlight = searchModel.highlight
            // The band the eye can actually read: below the title/tab bar, above
            // the floating quick-search pill. The pill floats, so the lines
            // behind it are not visible — reserve a whole number of lines
            // (derived from the live line height) rather than the pill's raw
            // height, so "half a line peeking over the pill" counts as hidden.
            let pillCover: CGFloat = searchModel.isVisible
                ? EditorChromeMetrics.quickSearchBarHeight + EditorChromeMetrics.quickSearchBarLift
                : 0
            let hiddenLines = pillCover > 0
                ? ceil(pillCover / max(effectiveLineHeight, 1))
                : 0
            let bottomReserve = min(hiddenLines * effectiveLineHeight,
                                    proxy.size.height * 0.4)
            let visibleTop = topEdgeHeight
            let visibleBottom = max(proxy.size.height - bottomReserve,
                                    visibleTop + effectiveLineHeight)
            // Reveal centres the match in both axes. Horizontally the anchor sits
            // at the hit's content centre (leading chrome + gutter + rect centre),
            // so `scrollTo(.center)` scrolls left or right to bring an off-screen
            // hit into view instead of pinning the viewport's current centre.
            let revealX = leadingChromeWidth + gutter.width + (highlight?.rect.midX ?? 0)
            // `scrollTo(.center)` centres the anchor in the scrollable region —
            // the viewport *below* the top safe-area bar. The readable band is
            // that same region cut short by the pill below, so its centre sits
            // `bottomReserve / 2` above the scroll centre. Carry exactly that
            // half-pill on the anchor; the top bar is already excluded by the
            // scroll centre itself, so subtracting it again pushed every upward
            // reveal back under the title band.
            let revealY = (highlight?.rect.midY ?? 0) + bottomReserve / 2
            // Same source as the halo: the hit measured by the model on the jump,
            // so the anchor cannot scroll to a rect the layout never produced.
            let findReplaceRevealY = findReplace.highlight?.rect.midY ?? 0

            ZStack(alignment: .topLeading) {
                Color(backgroundColor)

                // A two-axis ScrollView does not install macOS's variable-blur
                // edge filter. Give each axis its own native scroller instead.
                // Pin the vertical viewport inside the wider horizontal document
                // so its top bar and vertical indicator never travel sideways.
                ScrollView(.horizontal, showsIndicators: true) {
                ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        // These are real scroll-content spacers, rather than
                        // ScrollView content insets. At rest they reserve the
                        // sidebar + gutter, but horizontal scrolling can move
                        // both spaces completely out of the viewport so code
                        // travels underneath the fixed glass surfaces.
                        Color.clear
                            .frame(width: leadingChromeWidth + gutter.width,
                                   height: renderedHeight)

                        ZStack(alignment: .topLeading) {
                            if let storage = sharedTextStorage {
                                TextKit2EditorRepresentable(attributedString: attributedString, sharedTextStorage: storage, existingEditor: existingEditor)
                                    .frame(width: textContentWidth, height: renderedHeight)
                            } else {
                                TextKit2RenderRepresentable(attributedString: attributedString)
                                    .frame(width: textContentWidth, height: renderedHeight)
                            }

                            // Wrap-column guide — a subtle vertical rule at the
                            // fixed character column. Scrolls with the text.
                            if showWrapColumn {
                                Rectangle()
                                    .fill(Color(nsColor: gutter.separatorColor ?? NSColor(white: 0.5, alpha: 0.35)))
                                    .frame(width: 1, height: renderedHeight)
                                    .offset(x: EditorChromeMetrics.codeLeadingPadding + CGFloat(wrapColumn) * charWidth)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: textContentWidth, height: renderedHeight)

                        Color.clear
                            .frame(width: trailingChromeWidth,
                                   height: renderedHeight)
                    }
                    .overlay(alignment: .topLeading) {
                        // The current hit wears a halo stronger than the native
                        // selection: tint, rim, glow, and a one-shot ripple that
                        // replays on every jump (the token is the identity).
                        if searchModel.isVisible, let hit = highlight {
                            QuickSearchMatchHighlight(rect: hit.rect)
                                .id(searchModel.revealToken)
                                .offset(x: leadingChromeWidth + gutter.width)
                        }
                        // Both reveal anchors centre the target vertically only:
                        // their X sits at the viewport's current horizontal centre
                        // so the scroll never drifts sideways.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("quick-search-reveal")
                            .position(x: revealX, y: revealY)
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("find-replace-reveal")
                            .position(x: scrollOffset.x + proxy.size.width / 2, y: findReplaceRevealY)
                    }
                    .offset(x: -scrollOffset.x)
                    .padding(.top, topContentInset)
                    .padding(.bottom, bottomOverscroll)
                    .frame(minWidth: visibleEditorWidth,
                           minHeight: max(0, proxy.size.height - topEdgeHeight),
                           alignment: .topLeading)
                }
                // Progressive blur is the *native* edge effect: it frosts only
                // the scroll content (the code) as it passes beneath the pinned
                // band, never the fixed background colour behind the scroll view.
                // The bar must contain the real header: an all-clear bar reserves
                // space but macOS disables its variable-blur filter.
                .scrollEdgeEffectStyle(.soft, for: [.top, .leading, .trailing])
                .scrollEdgeEffectHidden(false, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    CodeScrollHeader(title: topBarTitle, symbol: topBarSymbol,
                                     leading: leadingChromeWidth > 0
                                        ? leadingChromeWidth + gutter.width + 16 : 144,
                                     trailing: max(trailingChromeWidth, 160),
                                     height: topEdgeHeight)
                }
                .coordinateSpace(name: "editor-scroll")
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scrollIndicators(.visible)
                // The vertical scroller stops below the floating chrome (tab strip
                // when visible, the title row otherwise) so it never runs up behind
                // the transparent top bars; the code itself keeps scrolling past
                // them into the progressive blur.
                // The local safe-area bar already reserves the top band; don't
                // apply that height a second time to the scroll indicator.
                .contentMargins(.top, 0,
                                for: .scrollIndicators)
                // Keep the bottom scroller out of the fixed line-number column.
                // The trailing safe-area bar independently keeps its end clear
                // of Pythia when that inspector is visible.
                .contentMargins(.leading, leadingChromeWidth + gutter.width,
                                for: .scrollIndicators)
                .contentMargins(.trailing, trailingChromeWidth,
                                for: .scrollIndicators)
                .contentMargins(.bottom, 0,
                                for: .scrollIndicators)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
                } action: { _, newOffset in
                    scrollOffset.y = newOffset
                }
                .task(id: searchModel.revealToken) {
                    guard let hit = searchModel.highlight else { return }
                    // Where the hit sits *right now*, in surface coordinates.
                    // `topEdgeHeight + content - scrollOffset` is the mapping the
                    // chrome uses; insets are already folded into `scrollOffset`.
                    let hitTop = topEdgeHeight + topContentInset + hit.rect.minY - scrollOffset.y
                    let hitBottom = topEdgeHeight + topContentInset + hit.rect.maxY - scrollOffset.y
                    // Horizontal position of the same hit: the text view sits after
                    // the leading chrome + gutter spacer, so fold that offset in and
                    // subtract the current horizontal scroll.
                    let hitLeft = leadingChromeWidth + gutter.width + hit.rect.minX - scrollOffset.x
                    let hitRight = leadingChromeWidth + gutter.width + hit.rect.maxX - scrollOffset.x
                    let visibleLeft = leadingChromeWidth + gutter.width
                    let visibleRight = proxy.size.width - trailingChromeWidth
                    // Already fully readable — including clear of the title band,
                    // the pill, and both horizontal edges — so leave the viewport
                    // alone. A search must not jerk the document for a hit the eye
                    // can see.
                    let verticallyVisible = hitTop >= visibleTop && hitBottom <= visibleBottom
                    let horizontallyVisible = hitLeft >= visibleLeft && hitRight <= visibleRight
                    guard !(verticallyVisible && horizontallyVisible) else { return }
                    let centreY = (hitTop + hitBottom) / 2
                    let verticalDistance = abs(centreY - (visibleTop + visibleBottom) / 2)
                    let centreX = (hitLeft + hitRight) / 2
                    let horizontalDistance = abs(centreX - (visibleLeft + visibleRight) / 2)
                    let distance = max(verticalDistance, horizontalDistance)
                    // One frame for the anchor to take its new position: a
                    // `scrollTo` in the same tick still targets the old hit,
                    // which is what made consecutive jumps land elsewhere.
                    try? await Task.sleep(for: .milliseconds(16))
                    // Near hits glide, far jumps cut: duration follows distance,
                    // and anything past three viewports lands instantly — a
                    // kilometre-long ease reads as lag, not as motion.
                    if distance > proxy.size.height * 3 || distance < 1 {
                        scrollProxy.scrollTo("quick-search-reveal", anchor: .center)
                    } else {
                        let duration = min(0.38, max(0.12, Double(distance) / 3200))
                        withAnimation(.easeInOut(duration: duration)) {
                            scrollProxy.scrollTo("quick-search-reveal", anchor: .center)
                        }
                    }
                }
                .onChange(of: findReplace.revealToken) { _, _ in
                    guard findReplace.highlight != nil else { return }
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo("find-replace-reveal", anchor: .center)
                    }
                }
                }
                .offset(x: scrollOffset.x)
                .frame(width: max(proxy.size.width,
                                  leadingChromeWidth + gutter.width + textContentWidth + trailingChromeWidth),
                       alignment: .leading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentMargins(.leading, leadingChromeWidth + gutter.width, for: .scrollIndicators)
                .contentMargins(.trailing, trailingChromeWidth, for: .scrollIndicators)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(geometry.contentOffset.x + geometry.contentInsets.leading, 0)
                } action: { _, newOffset in
                    scrollOffset.x = newOffset
                }

                // ONE surface, owned here because only this layer sits between
                // the scrolling code and the line numbers: the sidebar band
                // (window edge through the sheet's margin) and the line-number
                // column are a single rectangle of one material, one tint, one
                // opacity. No divider, no second card, no rounded inset — a
                // second surface at a different origin is precisely what read as
                // a seam. Its extent is decided here (leading band + gutter
                // width); the look is resolved upstream by the sidebar context.
                EditorChromeSurface(color: gutter.backgroundColor ?? NSColor.clear,
                                    opacity: Double(gutterBackgroundOpacity))
                    .frame(width: max(leadingChromeWidth + gutter.width, 1),
                           height: proxy.size.height, alignment: .topLeading)
                    // Folded away, the sheet no longer covers the window
                    // buttons — they float directly over this column. Fade its
                    // top out so the glass and the numbers dissolve before they
                    // collide with them; opened, the sheet's own band does that
                    // and the surface stays continuous to the window edge.
                    .mask {
                        if leadingChromeWidth == 0 {
                            // The traffic-light row owns the first `titleBarBand`
                            // points. Folded away, nothing of this column may
                            // surface there: the glass and the numbers both stay
                            // clear for the full band and only ramp in below it.
                            VStack(spacing: 0) {
                                Color.clear.frame(height: EditorChromeMetrics.titleBarBand - 4)
                                LinearGradient(colors: [.clear, .black],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: EditorChromeMetrics.titleBarBand)
                                Color.black
                            }
                        } else {
                            // Punch the floating sheet's footprint out of the
                            // unified band: the sheet carries its own glass tint
                            // (`.glassEffect(.regular.tint(_:))`), so this band
                            // must not frost the code a second time behind it — a
                            // second frost is exactly what buried the text under
                            // the panel. Even-odd: filled everywhere but the hole.
                            SidebarCardHole(
                                hole: CGRect(
                                    x: SidebarSheetGeometry.leading,
                                    y: SidebarSheetGeometry.top,
                                    width: max(leadingChromeWidth - SidebarSheetGeometry.horizontalInsets, 0),
                                    height: max(proxy.size.height - SidebarSheetGeometry.top, 0)
                                ),
                                cornerRadius: SidebarSheetGeometry.sheetCornerRadius
                            )
                            .fill(style: FillStyle(eoFill: true))
                        }
                    }
                    .allowsHitTesting(false)

                // Pinned column divider: a 1px rule between the number column and
                // code, rooted to the window (top edge through the bottom of the
                // scrollable area) instead of scrolling with the numbers. The
                // numbers scroll with the document; the divider is chrome and
                // stays put while content rides beneath it.
                if let separator = gutter.separatorColor {
                    Rectangle()
                        .fill(Color(nsColor: separator))
                        .frame(width: 1, height: proxy.size.height)
                        .offset(x: leadingChromeWidth + gutter.width - 1)
                        .allowsHitTesting(false)
                }

                // The numbers must sit above the material (otherwise it blurs
                // them away everywhere), while remaining vertically locked to
                // the document. This dedicated top layer fades from invisible
                // through soft blur to sharp text only at the titlebar edge.
                ProgressiveGutterNumbers(attributedString: attributedString,
                                         gutter: numbersOnlyGutter,
                                         contentHeight: renderedHeight + bottomOverscroll,
                                         verticalOffset: topEdgeHeight + topContentInset - scrollOffset.y,
                                         sourceLayoutManager: existingEditor?.layoutManager,
                                         foldState: foldState,
                                         onFoldToggle: onFoldToggle)
                    .frame(width: gutter.width + leftOverhang, height: proxy.size.height, alignment: .top)
                    .offset(x: leadingChromeWidth - leftOverhang)


                // The incremental quick-search pill is attached to *this* surface
                // further down, so it always centres in the code column it
                // searches. Find & replace (⌘F / ⌘⌥F) lives in its own TextMate-
                // style window. What stays here is what only the scroll surface
                // can do: the reveal anchor, re-scrolled on every `revealToken`.
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            // The pill belongs to the scroll surface, not to the window: it is
            // centred in the code column this surface actually renders, so an
            // open sidebar or Pythia can never shift it off the text it searches.
            .overlay(alignment: .bottom) {
                QuickSearchDock(model: searchModel)
                    .padding(.leading, leadingChromeWidth + gutter.width)
                    .padding(.trailing, trailingChromeWidth)
            }
            .animation(.easeInOut(duration: 0.18), value: searchModel.isVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard let view = notification.object as? NSTextView, view === existingEditor else { return }
            let string = view.string as NSString
            let sel = view.selectedRange()
            let cursor = min(sel.location, string.length)
            activeLine = Self.lineNumber(at: cursor, in: string)
            if sel.length > 0, sel.location < string.length {
                let start = Self.lineNumber(at: sel.location, in: string)
                let endIdx = max(sel.location, min(NSMaxRange(sel) - 1, max(string.length - 1, 0)))
                let end = Self.lineNumber(at: endIdx, in: string)
                selectedLineRange = start...end
            } else {
                selectedLineRange = nil
            }
        }
    }

    /// 1-based line number for a character index, counting only newlines.
    private static func lineNumber(at index: Int, in string: NSString) -> Int {
        let end = min(max(index, 0), string.length)
        var line = 1
        var i = 0
        while i < end {
            if string.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }
}

private struct ProgressiveGutterNumbers: View {
    let attributedString: NSAttributedString
    let gutter: EditorGutterStyle
    let contentHeight: CGFloat
    let verticalOffset: CGFloat
    var sourceLayoutManager: NSLayoutManager? = nil
    var foldState: FoldState? = nil
    var onFoldToggle: ((FoldRegion) -> Void)? = nil

    /// One title band plus a ramp: the numbers stay invisible until the
    /// traffic-light row ends, then arrive soft and sharpen by ~76pt.
    private let transitionHeight: CGFloat = EditorChromeMetrics.titleBarBand + 32

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sharp numbers take over progressively below the titlebar.
            numberLayer
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .clear, location: 0.58),
                                               .init(color: .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: transitionHeight)
                        Color.black
                    }
                }

            // A narrow blurred middle band makes this a true progressive blur,
            // rather than merely an opacity gradient.
            numberLayer
                .blur(radius: 5)
                .opacity(0.55)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.56),
                            .init(color: .black, location: 0.80),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                            .frame(height: transitionHeight)
                        Color.clear
                    }
                }
        }
        .clipped()
    }

    private var numberLayer: some View {
        GutterRenderRepresentable(attributedString: attributedString,
                                  gutter: gutter,
                                  sourceLayoutManager: sourceLayoutManager,
                                  foldState: foldState,
                                  onFoldToggle: onFoldToggle)
            .frame(width: gutter.width + gutter.leftOverhang, height: contentHeight)
            .offset(y: verticalOffset)
    }
}
