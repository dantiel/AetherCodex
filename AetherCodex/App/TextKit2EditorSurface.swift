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
}

// MARK: - Gutter style

/// Visual + geometric config for the line-number gutter, resolved from the
/// active theme. The gutter is drawn by `GutterRenderView`, a pinned sibling to
/// the horizontal text scroller, so line numbers stay put during horizontal scroll.
struct EditorGutterStyle {
    var activeLine: Int = 1
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
    var selectionBackground: NSColor = .controlAccentColor
    var selectionForeground: NSColor = .labelColor
}

// MARK: - TextKit 2 measurement

/// Measures a document's full layout extent using TextKit 2, independently of
/// any view. Used to size the SwiftUI `ScrollView` content so SwiftUI owns the
/// scrolling and the native scroll-edge effect can engage.
enum TextKit2Layout {
    static func measure(_ attributedString: NSAttributedString, containerWidth: CGFloat) -> CGSize {
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
        layoutManager = NSLayoutManager()

        // TextContainer: no width limit for horizontal scroll
        textContainer = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        // NSTextView using TextKit 1
        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        // Vertical breathing room is owned by TextKit2ScrollSurface so the
        // editable and passive render paths share identical geometry.
        textView.textContainerInset = NSSize(width: 8, height: 0)
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
        editor.textContainerInset = NSSize(width: 8, height: 0)
        editor.autoresizingMask = []
        editor.isHorizontallyResizable = true
        editor.isEditable = true
        editor.allowsUndo = true
        textContainer.widthTracksTextView = false
        addSubview(editor)
        needsLayout = true
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
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private var lineOrigins: [(number: Int, rect: CGRect)] = []

    /// Line-number gutter configuration (width + colors), resolved from the theme.
    var gutter: EditorGutterStyle = EditorGutterStyle() {
        didSet { needsDisplay = true }
    }

    /// The editor's live TextKit 1 layout manager. Line origins are derived from
    /// its *actual* line-fragment rects, so numbers and the active-line highlight
    /// stay locked to the text even when syntax highlighting gives each line its
    /// own font size / line height. Falls back to uniform spacing when nil.
    weak var sourceLayoutManager: NSLayoutManager? {
        didSet { needsDisplay = true }
    }

    private let foldGutterWidth: CGFloat = 14
    private let numberLeftPad: CGFloat = 6
    private let numberGap: CGFloat = 12

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

        // Same unconstrained container as the text view, so line origins match.
        let container = NSTextContainer(size: CGSize(width: 0, height: 0))
        container.widthTracksTextView = false
        layoutManager.textContainer = container
    }

    override var isFlipped: Bool { true }

    func setAttributedString(_ attributedString: NSAttributedString) {
        rebuildLineOrigins(from: attributedString)
        needsDisplay = true
    }

    /// Derives per-line origins from the live layout manager's fragment rects.
    /// The editor is non-wrapping, so each source line is one fragment — but line
    /// *heights* vary per line (headings, emphasis, image lines, …), so a single
    /// constant `lineHeight` can never keep numbers aligned with the text.
    private func rebuildLineOrigins(from attributedString: NSAttributedString) {
        if let lm = sourceLayoutManager, lm.numberOfGlyphs > 0,
           let storage = lm.textStorage {
            lineOrigins = Self.lineOrigins(from: lm, string: storage.string as NSString,
                                           width: gutter.width)
            return
        }
        // Passive fallback: no live layout manager — assume uniform height.
        let lineCount = attributedString.string.components(separatedBy: "\n").count
        let height = max(gutter.lineHeight, 1)
        lineOrigins = (1...lineCount).map { number in
            (number: number, rect: CGRect(x: 0, y: CGFloat(number - 1) * height,
                                           width: gutter.width, height: height))
        }
    }

    /// Walks the layout manager's fragments top-to-bottom and maps each to its
    /// 1-based source line. Wrapped continuations merge into their paragraph so a
    /// single number + one full-height highlight covers the whole visual line.
    private static func lineOrigins(from lm: NSLayoutManager, string: NSString,
                                    width: CGFloat) -> [(number: Int, rect: CGRect)] {
        var result: [(number: Int, rect: CGRect)] = []
        let starts = lineStarts(for: string)
        var startIdx = 0
        var currentGlyph = 0
        let maxGlyph = lm.numberOfGlyphs
        var guardCount = 0

        while currentGlyph < maxGlyph, guardCount < 200_000 {
            guardCount += 1
            var fragGlyphRange = NSRange(location: 0, length: 0)
            let fragRect = SafeLineFragmentRect(lm, UInt(currentGlyph), &fragGlyphRange)
            guard fragGlyphRange.location != NSNotFound, fragGlyphRange.length > 0 else { break }

            let fragCharRange = SafeCharacterRangeForGlyphRange(lm, fragGlyphRange)
            if fragCharRange.location != NSNotFound, fragCharRange.length > 0 {
                while startIdx + 1 < starts.count && starts[startIdx + 1] <= fragCharRange.location {
                    startIdx += 1
                }
                let lineNumber = startIdx + 1
                let top = fragRect.minY
                let bottom = fragRect.minY + fragRect.height
                if let last = result.last, last.number == lineNumber {
                    let newTop = min(last.rect.minY, top)
                    let newBottom = max(last.rect.maxY, bottom)
                    result[result.count - 1] = (number: lineNumber,
                                                rect: CGRect(x: 0, y: newTop, width: width, height: newBottom - newTop))
                } else {
                    result.append((number: lineNumber,
                                   rect: CGRect(x: 0, y: top, width: width, height: bottom - top)))
                }
            }

            let next = NSMaxRange(fragGlyphRange)
            if next <= currentGlyph { break }
            currentGlyph = next
        }
        return result
    }

    /// Character index of each line start (line 1 begins at 0; each \n or \r
    /// opens the next line immediately after it).
    private static func lineStarts(for string: NSString) -> [Int] {
        var starts: [Int] = [0]
        var i = 0
        while i < string.length {
            let ch = string.character(at: i)
            if ch == 0x0A || ch == 0x0D { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard gutter.width > 0 else { return }

        // The gutter background is a translucent glass surface applied by
        // `TextKit2ScrollSurface` (material + tint). This view stays transparent
        // so the frosted material behind it shows through as blur, not flat fill.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutter.font,
            .foregroundColor: gutter.textColor,
        ]

        for entry in lineOrigins {
            let frame = entry.rect
            guard frame.intersects(dirtyRect) else { continue }
            let text = "\(entry.number)" as NSString
            let size = text.size(withAttributes: attrs)
            // Right-align numbers, leaving the fold gutter + gap to the separator.
            let x = gutter.width - foldGutterWidth - numberGap - size.width
            let y = frame.origin.y + (frame.height - size.height) / 2
            var numberAttributes = attrs
            if entry.number == gutter.activeLine {
                gutter.selectionBackground.setFill()
                NSRect(x: 0, y: frame.minY, width: gutter.width, height: frame.height).fill()
                numberAttributes[.foregroundColor] = gutter.selectionForeground
            }
            text.draw(at: NSPoint(x: x, y: y), withAttributes: numberAttributes)
        }

        if let separator = gutter.separatorColor {
            separator.setFill()
            let sepRect = NSRect(x: gutter.width - 1, y: dirtyRect.minY,
                                 width: 1, height: dirtyRect.height)
            sepRect.fill()
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
    /// Shared text storage from EditorViewController — when provided, editor becomes editable
    var sharedTextStorage: NSTextStorage? = nil
    var existingEditor: NSTextView? = nil
    @State private var scrollOffset: CGPoint = .zero
    @State private var activeLine = 1

    var body: some View {
        GeometryReader { proxy in
            // Two visual code lines of breathing room below the floating title.
            // This is part of the scroll content, so it naturally disappears as
            // the user scrolls down instead of becoming another fixed toolbar.
            let topContentInset: CGFloat = 34
            let docSize = TextKit2Layout.measure(attributedString, containerWidth: 0)
            let visibleEditorWidth = max(proxy.size.width - leadingChromeWidth - trailingChromeWidth, 1)
            let viewportTextWidth = max(visibleEditorWidth - gutter.width, 1)
            let textContentWidth = max(docSize.width + 24, viewportTextWidth)
            let renderedHeight = max(docSize.height, proxy.size.height - topContentInset)
            let numbersOnlyGutter = EditorGutterStyle(
                activeLine: activeLine,
                width: gutter.width,
                font: gutter.font,
                lineHeight: gutter.lineHeight,
                textColor: gutter.textColor,
                separatorColor: nil,
                backgroundColor: nil,
                selectionBackground: gutter.selectionBackground,
                selectionForeground: gutter.selectionForeground
            )

            ZStack(alignment: .topLeading) {
                Color(backgroundColor)

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

                        if let storage = sharedTextStorage {
                            TextKit2EditorRepresentable(attributedString: attributedString, sharedTextStorage: storage, existingEditor: existingEditor)
                                .frame(width: textContentWidth, height: renderedHeight)
                        } else {
                            TextKit2RenderRepresentable(attributedString: attributedString)
                                .frame(width: textContentWidth, height: renderedHeight)
                        }

                        Color.clear
                            .frame(width: trailingChromeWidth,
                                   height: renderedHeight)
                    }
                    .padding(.top, topContentInset)
                    .frame(minWidth: visibleEditorWidth,
                           minHeight: proxy.size.height,
                           alignment: .topLeading)
                }
                // Document-height overlays must not enlarge the scroll viewport.
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scrollIndicators(.visible)
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

                // One uninterrupted fixed material surface above the scrolling
                // code. Only the numbers participate in the native progressive
                // scroll-edge effect; the gutter background never disappears.
                ZStack(alignment: .trailing) {
                    Rectangle().fill(.ultraThinMaterial)
                    Color(nsColor: (gutter.backgroundColor ?? NSColor.clear).withAlphaComponent(1)).opacity(0.86)
                    if let separator = gutter.separatorColor {
                        Color(nsColor: separator).frame(width: 1)
                    }
                }
                .frame(width: gutter.width)
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
                .offset(x: leadingChromeWidth)
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
                    .frame(width: gutter.width, height: proxy.size.height, alignment: .top)
                    .offset(x: leadingChromeWidth)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard let view = notification.object as? NSTextView, view === existingEditor else { return }
            let string = view.string as NSString
            let cursor = min(view.selectedRange().location, string.length)
            activeLine = string.substring(to: cursor).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
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
            .frame(width: gutter.width, height: contentHeight)
            .offset(y: verticalOffset)
    }
}