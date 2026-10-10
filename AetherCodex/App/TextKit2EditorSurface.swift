import SwiftUI
import AppKit
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
    var leftOverhang: CGFloat = 8
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

    private let foldGutterWidth: CGFloat = 14
    private let numberGap: CGFloat = 12
    /// Observer for the adopted text view's selection changes (see
    /// `rewireSelectionObserver()`). Held so it can be removed on deinit.
    private var selectionObserver: NSObjectProtocol? = nil

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
        guard let tv = sourceLayoutManager?.textContainers.first?.textView else { return }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: tv,
            queue: nil
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    func setAttributedString(_ attributedString: NSAttributedString) {
        // Prefer the live layout manager's text storage (the exact text the
        // fragments are laid out from) so line starts never lag the SwiftUI
        // snapshot. Rebuild line count + line-start index only when the document
        // actually changed — never on a scroll/selection change, which is what
        // caused the gutter to re-walk the whole layout manager every frame before.
        let liveString = sourceLayoutManager?.textStorage?.string as NSString?
        let source = liveString ?? (attributedString.string as NSString)
        let identity = ObjectIdentifier(attributedString)
        if identity != cachedStringIdentity || source.length != cachedSourceLength {
            cachedStringIdentity = identity
            cachedSourceLength = source.length
            lineCount = source.length > 0 ? 1 : 0
            lineStartOffsets = []
            if source.length > 0 {
                lineStartOffsets.append(0)
                var i = 0
                while i < source.length {
                    if source.character(at: i) == 0x0A {
                        lineCount += 1
                        lineStartOffsets.append(i + 1)
                    }
                    i += 1
                }
            }
        }
        needsDisplay = true
    }

    /// Uniform per-line pitch, used only as a fallback when no live layout manager
    /// is attached (passive render path). The editable path places every number at
    /// its own fragment origin instead.
    private var liveLineHeight: CGFloat {
        if let lm = sourceLayoutManager, lm.numberOfGlyphs > 0 {
            let height = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
            if height > 0 { return height }
        }
        return gutter.lineHeight
    }

    /// Exact line rect for a 1-based line number, read from the live layout
    /// manager's fragment for that line. A taller line (emoji, larger inline face)
    /// keeps its number locked to it. Falls back to the uniform pitch when no
    /// layout manager is attached.
    private func rect(forLine number: Int) -> CGRect {
        if let lm = sourceLayoutManager, lm.numberOfGlyphs > 0,
           number > 0, number - 1 < lineStartOffsets.count {
            let charOffset = lineStartOffsets[number - 1]
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: charOffset, length: 0),
                                           actualCharacterRange: nil)
            if glyphRange.location < lm.numberOfGlyphs {
                let rect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                if rect.height > 0 { return rect }
            }
        }
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
            lines.append((lineIndex + 1, rect, isContinuation))
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
            if bandFirst <= bandLast {
                let top = rect(forLine: bandFirst).minY
                let bottom = rect(forLine: bandLast).maxY
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

        // ── Vertical divider: 1px rule between the number column and code ──
        // Drawn here (not in the material surface) because this view is the one
        // guaranteed to render; a trailing `Color.frame(width: 1)` inside the
        // fixed material ZStack was collapsing to zero height and vanishing.
        if let divider = gutter.separatorColor {
            divider.setFill()
            NSRect(x: contentWidth - 1, y: 0, width: 1, height: bounds.height).fill()
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

    func makeNSView(context: Context) -> GutterRenderView {
        let view = GutterRenderView(frame: .zero)
        view.gutter = gutter
        view.sourceLayoutManager = sourceLayoutManager
        view.setAttributedString(attributedString)
        return view
    }

    func updateNSView(_ nsView: GutterRenderView, context: Context) {
        nsView.gutter = gutter
        nsView.sourceLayoutManager = sourceLayoutManager
        nsView.setAttributedString(attributedString)
    }
}

// MARK: - SwiftUI-owned scroll surface

/// The editor document, scrolled by SwiftUI. A vertical `ScrollView` owns the
/// top scroll-edge blur for both the pinned gutter and the text; the text sits in
/// a nested horizontal `ScrollView` so horizontal scrolling never moves the gutter.
/// When sharedTextStorage is provided, the editor is editable and syncs with EditorViewController.
struct TextKit2ScrollSurface: View {
    let attributedString: NSAttributedString
    let backgroundColor: Color
    let gutter: EditorGutterStyle
    let leadingChromeWidth: CGFloat
    let trailingChromeWidth: CGFloat
    /// Chrome rows (tab strip) sitting above the surface: their height is added
    /// to the top scroll inset so the first code line clears them at rest.
    let topChromeInset: CGFloat
    /// Shared text storage from EditorViewController — when provided, editor becomes editable
    var sharedTextStorage: NSTextStorage? = nil
    var existingEditor: NSTextView? = nil
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

    @State private var scrollOffset: CGPoint = .zero
    @State private var activeLine = 1
    @State private var selectedLineRange: ClosedRange<Int>? = nil

    init(attributedString: NSAttributedString,
         backgroundColor: Color,
         gutter: EditorGutterStyle,
         leadingChromeWidth: CGFloat,
         trailingChromeWidth: CGFloat,
         topChromeInset: CGFloat = 0,
         sharedTextStorage: NSTextStorage? = nil,
         existingEditor: NSTextView? = nil,
         searchModel: QuickSearchModel,
         findReplace: FindReplaceModel,
         showWrapColumn: Bool = false,
         wrapColumn: Int = 80,
         lineCount: Int = 1,
         maxLineWidth: Int = 0) {
        self.attributedString = attributedString
        self.backgroundColor = backgroundColor
        self.gutter = gutter
        self.leadingChromeWidth = leadingChromeWidth
        self.trailingChromeWidth = trailingChromeWidth
        self.topChromeInset = topChromeInset
        self.sharedTextStorage = sharedTextStorage
        self.existingEditor = existingEditor
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
            // plus whatever chrome rows (the tab strip) sit above the surface.
            // This is part of the scroll content, so it naturally disappears as
            // the user scrolls down instead of becoming another fixed toolbar.
            let topContentInset: CGFloat = EditorChromeMetrics.baseContentInset + topChromeInset
                + (topChromeInset > 0 ? EditorChromeMetrics.tabBarContentClearance : 0)
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
            let renderedHeight = max(docHeight, proxy.size.height - topContentInset)
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

            // Vertical center of the search-reveal target, in the scroll content's
            // own coordinate space (relative to the HStack top). The reveal anchor
            // below is positioned here and scrolled into view on each match.
            // Exact layout-manager Y when available; arithmetic estimate as a
            // fallback while the adopted editor's layout is still warming up.
            let revealY = searchModel.currentMatchCenterY
                ?? CGFloat((searchModel.pendingRevealLine ?? 1) - 1) * effectiveLineHeight
                    + effectiveLineHeight / 2
            let findReplaceRevealY = CGFloat((findReplace.pendingRevealLine ?? 1) - 1) * effectiveLineHeight
                + effectiveLineHeight / 2

            ZStack(alignment: .topLeading) {
                Color(backgroundColor)

                ScrollViewReader { scrollProxy in
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
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
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("quick-search-reveal")
                            .position(x: 0, y: revealY)
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id("find-replace-reveal")
                            .position(x: 0, y: findReplaceRevealY)
                    }
                    .padding(.top, topContentInset)
                    .frame(minWidth: visibleEditorWidth,
                           minHeight: proxy.size.height,
                           alignment: .topLeading)
                }
                // Document-height overlays must not enlarge the scroll viewport.
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Progressive blur lives on the *scroll content only* — the
                // background color must stay solid to the very top of the window.
                .scrollEdgeEffectStyle(.soft, for: [.top, .leading, .trailing])
                .scrollIndicators(.visible)
                // The vertical scroller stops below the floating chrome (tab strip
                // when visible, the title row otherwise) so it never runs up behind
                // the transparent top bars; the code itself keeps scrolling past
                // them into the progressive blur.
                .contentMargins(.top, EditorChromeMetrics.scrollIndicatorTopInset(showsTabBar: topChromeInset > 0),
                                for: .scrollIndicators)
                // Keep the bottom scroller out of the fixed line-number column.
                // The trailing safe-area bar independently keeps its end clear
                // of Pythia when that inspector is visible.
                .contentMargins(.leading, leadingChromeWidth + gutter.width,
                                for: .scrollIndicators)
                .contentMargins(.trailing, trailingChromeWidth,
                                for: .scrollIndicators)
                .onScrollGeometryChange(for: CGPoint.self) { geometry in
                    CGPoint(
                        x: max(geometry.contentOffset.x + geometry.contentInsets.leading, 0),
                        y: max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
                    )
                } action: { _, newOffset in
                    scrollOffset = newOffset
                }
                .onChange(of: searchModel.revealToken) { _, _ in
                    guard searchModel.pendingRevealLine != nil else { return }
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo("quick-search-reveal", anchor: .center)
                    }
                }
                .onChange(of: findReplace.revealToken) { _, _ in
                    guard findReplace.pendingRevealLine != nil else { return }
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo("find-replace-reveal", anchor: .center)
                    }
                }
                }

                // One uninterrupted fixed material surface above the scrolling
                // code. Only the numbers participate in the native progressive
                // scroll-edge effect; the gutter background never disappears.
                ZStack(alignment: .trailing) {
                    Rectangle().fill(.ultraThinMaterial)
                    Color(nsColor: (gutter.backgroundColor ?? NSColor.clear).withAlphaComponent(1)).opacity(0.86)
                    if let separator = gutter.separatorColor {
                        // Rectangle (not Color) guarantees a full-height 1px rule;
                        // a bare Color.frame(width: 1) collapses to zero height and
                        // the divider silently disappears.
                        Rectangle().fill(Color(nsColor: separator)).frame(width: 1)
                    }
                }
                .frame(width: gutter.width + leftOverhang)
                .frame(maxHeight: .infinity)
                .mask {
                    if leadingChromeWidth == 0 {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 28)
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 44)
                            Color.black
                        }
                    } else {
                        Color.black
                    }
                }
                .offset(x: leadingChromeWidth - leftOverhang)
                .allowsHitTesting(false)

                // The numbers must sit above the material (otherwise it blurs
                // them away everywhere), while remaining vertically locked to
                // the document. This dedicated top layer fades from invisible
                // through soft blur to sharp text only at the titlebar edge.
                ProgressiveGutterNumbers(attributedString: attributedString,
                                         gutter: numbersOnlyGutter,
                                         contentHeight: renderedHeight,
                                         verticalOffset: topContentInset - scrollOffset.y,
                                         sourceLayoutManager: existingEditor?.layoutManager)
                    .frame(width: gutter.width + leftOverhang, height: proxy.size.height, alignment: .top)
                    .offset(x: leadingChromeWidth - leftOverhang)
                    .allowsHitTesting(false)

                // Incremental quick-search bar (Ctrl+S), floating above the
                // status bar. Kept in this ZStack so it hovers over the code
                // and never enlarges the scroll viewport. Bottom-aligned and
                // inset past the gutter + chrome so it stays clear of the
                // sidebar and the line-number column.
                if searchModel.isVisible {
                    HStack {
                        Spacer()
                        QuickSearchBar(model: searchModel)
                        Spacer()
                    }
                    .padding(.leading, leadingChromeWidth + gutter.width)
                    .padding(.trailing, trailingChromeWidth)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
                }

                // TextMate-style find & replace dialog (⌘F / ⌘⌥F). Floats above
                // the same bottom band, polymorphic around scope + replace mode.
                if findReplace.isVisible {
                    HStack {
                        Spacer()
                        FindReplaceBar(model: findReplace)
                        Spacer()
                    }
                    .padding(.leading, leadingChromeWidth + gutter.width)
                    .padding(.trailing, trailingChromeWidth)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: searchModel.isVisible)
            .animation(.easeInOut(duration: 0.18), value: findReplace.isVisible)
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

    private let transitionHeight: CGFloat = 72

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sharp numbers take over progressively below the titlebar.
            numberLayer
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .clear, location: 0.50),
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
                            .init(color: .clear, location: 0.40),
                            .init(color: .black, location: 0.68),
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
                                  sourceLayoutManager: sourceLayoutManager)
            .frame(width: gutter.width + gutter.leftOverhang, height: contentHeight)
            .offset(y: verticalOffset)
    }
}