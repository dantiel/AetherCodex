import Cocoa
import CSafeLayout

// MARK: - Line Number Gutter

/// Fixed-position gutter view — sits left of the scroll view, doesn't scroll.
/// Text scrolls behind it; line numbers are drawn at screen positions matching
/// the visible text lines.
/// Selection highlighting follows TextMate conventions: full-width background rects
/// with top/bottom 1px borders, middle-dot for wrapped continuation lines.
final class LineNumberRulerView: NSView {

    override var isFlipped: Bool { true }

    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    var textColor: NSColor = .tertiaryLabelColor
    var lineHighlightColor: NSColor?

    // MARK: - Selection gutter colors (themeable)

    var selectionBackground: NSColor = NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 0.4)
    var selectionForeground: NSColor = NSColor(white: 0.85, alpha: 1.0)
    var selectionBorder: NSColor = NSColor(red: 0.00, green: 0.22, blue: 0.44, alpha: 0.8)

    // MARK: - Folding

    var foldRegions: [FoldRegion] = []
    weak var foldState: FoldState?
    var onFoldToggle: ((FoldRegion) -> Void)?

    var separatorColor: NSColor?
    var rulerBackgroundColor: NSColor?

    /// Called when the measured number-width changes (e.g. 99→100 lines).
    /// Parent should re-layout to adjust scroll view position.
    var onWidthChanged: (() -> Void)?

    private let foldGutterWidth: CGFloat = 14
    private let triangleSize: CGFloat = 5
    private let numberLeftPad: CGFloat = 6   // padding from left edge to line numbers
    private let numberGap: CGFloat = 12      // padding from line number right edge to separator
    private var foldToggleColor: NSColor { textColor.withAlphaComponent(0.5) }
    private var lastLineCount = 0
    private var measuredNumberWidth: CGFloat = 20

    /// Current gutter width based on widest line number.
    var gutterWidth: CGFloat {
        ceil(foldGutterWidth + numberLeftPad + measuredNumberWidth + numberGap)
    }

    // MARK: - Init

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(frame: .zero)
        self.textView = textView
        self.scrollView = scrollView
        self.wantsLayer = true
        self.layer?.isOpaque = false

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewScrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipViewScrolled() { needsDisplay = true }
    @objc private func textDidChange()     {
        needsDisplay = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func invalidateWidthCache() {
        lastLineCount = 0
        needsDisplay = true
    }

    // MARK: - Drawing

    private var drawCount = 0
    override func draw(_ dirtyRect: NSRect) {
        // Background provided by layer.backgroundColor (set in applyThemeChrome).
        // No fill needed — single source, no compositing.
        drawCount += 1
        if drawCount <= 5 || drawCount % 50 == 0 {
            NSLog("[ruler] draw #%d frame=%@ super=%@ dirty=%@", drawCount,
                  NSStringFromRect(frame), String(describing: superview?.className),
                  NSStringFromRect(dirtyRect))
        }

        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let nsString = textView.string as NSString
        let inset = textView.textContainerInset
        let scrollOffset = scrollView?.contentView.bounds.origin.y ?? 0

        guard nsString.length > 0 else { return }

        // ── Dynamic width ──
        let totalLines = lineNumberForCharacter(at: nsString.length, in: nsString)
        if totalLines != lastLineCount {
            lastLineCount = totalLines
            let maxNum = String(totalLines)
            let newWidth = maxNum.size(withAttributes: [.font: font]).width
            if abs(newWidth - measuredNumberWidth) > 0.5 {
                measuredNumberWidth = newWidth
                onWidthChanged?()
            }
        }

        // ── Visible glyph range (document coords → screen via scrollOffset) ──
        let docMinY = dirtyRect.minY + scrollOffset - inset.height
        let docMaxY = dirtyRect.maxY + scrollOffset - inset.height
        let visibleDocRect = NSRect(x: 0, y: docMinY, width: 1, height: max(docMaxY - docMinY, 1))
        if drawCount <= 8 {
            NSLog("[ruler] glyphs=%ld scrollOffset=%.0f insetY=%.0f docRect=%@",
                  layoutManager.numberOfGlyphs, scrollOffset, inset.height, NSStringFromRect(visibleDocRect))
        }
        guard layoutManager.numberOfGlyphs > 0 else { return }
        let glyphRange = SafeGlyphRangeForBoundingRect(layoutManager, visibleDocRect, textContainer)
        if drawCount <= 8 {
            NSLog("[ruler] glyphRange=%@ ng=%ld", NSStringFromRange(glyphRange), layoutManager.numberOfGlyphs)
        }
        guard glyphRange.location != NSNotFound,
              glyphRange.length > 0,
              NSMaxRange(glyphRange) <= layoutManager.numberOfGlyphs else { return }

        // ── Selection range → character-range set for gutter highlight ──
        let selRange = textView.selectedRange()
        let hasSelection = selRange.length > 0 && selRange.location < nsString.length

        // ── Current visual-line fragment (caret position) ──
        let curFragGlyphRange: NSRange? = {
            let selLoc = textView.selectedRange().location
            guard selLoc < nsString.length else { return nil }
            let glyphIdx = Int(SafeGlyphIndexForCharacter(layoutManager, UInt(selLoc)))
            guard glyphIdx != NSNotFound else { return nil }
            guard glyphIdx < layoutManager.numberOfGlyphs else { return nil }
            var fg = NSRange()
            _ = SafeLineFragmentRect(layoutManager, UInt(glyphIdx), &fg)
            return fg.location != NSNotFound ? fg : nil
        }()

        let numberRight: CGFloat = bounds.width - numberGap
        let gutterW = bounds.width

        // ── Pass 1: Collect all visible fragment data ──
        struct FragInfo {
            let screenY: CGFloat
            let height: CGFloat
            let fragCharRange: NSRange
            let fragGlyphRange: NSRange
            let isFirstOfPara: Bool
            let paraLineNumber: Int
        }
        var frags: [FragInfo] = []
        var paraLineNumber = 0
        var lastParaEnd = 0

        let fullLength = nsString.length
        let maxGlyph = min(NSMaxRange(glyphRange), layoutManager.numberOfGlyphs)
        var currentGlyph = glyphRange.location
        var loopGuard = 0

        while currentGlyph < maxGlyph, loopGuard < 1000 {
            loopGuard += 1
            // Re-check live glyph count — word-wrap reflow can shrink it mid-loop
            guard currentGlyph < layoutManager.numberOfGlyphs else { break }
            var fragGlyphRange = NSRange(location: 0, length: 0)
            let fragRect = SafeLineFragmentRect(layoutManager, UInt(currentGlyph), &fragGlyphRange)
            guard fragGlyphRange.location != NSNotFound,
                  fragGlyphRange.length > 0 else { break }

            let screenY = fragRect.minY + inset.height - scrollOffset
            let h = fragRect.height

            if screenY + h > dirtyRect.minY, screenY < dirtyRect.maxY {
                // Validate glyph range before conversion — stale ranges crash characterRange
                // Use LIVE numberOfGlyphs, not a captured let — word-wrap reflow shrinks glyph count
                guard fragGlyphRange.location != NSNotFound,
                      NSMaxRange(fragGlyphRange) <= layoutManager.numberOfGlyphs,
                      layoutManager.isValidGlyphIndex(fragGlyphRange.location) else { break }
                let fragCharRange = SafeCharacterRangeForGlyphRange(layoutManager, fragGlyphRange)
                if fragCharRange.location != NSNotFound,
                   fragCharRange.length > 0,
                   fragCharRange.location < fullLength,
                   NSMaxRange(fragCharRange) <= fullLength {
                    let isFirst = fragCharRange.location >= lastParaEnd
                    if isFirst {
                        paraLineNumber = self.lineNumberForCharacter(at: fragCharRange.location, in: nsString)
                        let paraRange = nsString.safeLineRange(for: fragCharRange)
                        lastParaEnd = NSMaxRange(paraRange)
                    }
                    frags.append(FragInfo(screenY: screenY, height: h,
                                           fragCharRange: fragCharRange, fragGlyphRange: fragGlyphRange,
                                           isFirstOfPara: isFirst, paraLineNumber: paraLineNumber))
                }
            }

            let next = NSMaxRange(fragGlyphRange)
            if next <= currentGlyph { break }
            currentGlyph = next
        }

        // ── Pass 2: Determine selection-affected fragment ranges (for grouping) ──
        var selFragIndices = IndexSet()
        if hasSelection {
            for (i, f) in frags.enumerated() {
                if NSIntersectionRange(f.fragCharRange, selRange).length > 0 {
                    selFragIndices.insert(i)
                }
            }
        }

        // ── Pass 2.5: Draw selection backgrounds + borders (full-width, flat rects) ──
        if !selFragIndices.isEmpty {
            let selBg = selectionBackground
            let selBd = selectionBorder
            
            // Group consecutive selected fragments by paragraph → draw combined rect + top/bottom borders
            var runStart: Int? = nil
            for i in 0...frags.count {
                let inRun = i < frags.count && selFragIndices.contains(i)
                if inRun && runStart == nil {
                    runStart = i
                } else if !inRun, let start = runStart {
                    let runEnd = i - 1
                    let firstFrag = frags[start]
                    let lastFrag = frags[runEnd]
                    let topY = firstFrag.screenY
                    let botY = lastFrag.screenY + lastFrag.height
                    
                    // Background: full-wide rect from top of first fragment to bottom of last
                    let bgRect = NSRect(x: 0, y: topY + 1, width: gutterW, height: max(0, botY - topY - 2))
                    selBg.setFill()
                    bgRect.fill()
                    
                    // Top border: 1px line at top of first fragment
                    let topBorder = NSRect(x: 0, y: topY, width: gutterW, height: 1)
                    selBd.setFill()
                    topBorder.fill()
                    
                    // Bottom border: 1px line at bottom of last fragment
                    let botBorder = NSRect(x: 0, y: botY - 1, width: gutterW, height: 1)
                    selBd.setFill()
                    botBorder.fill()
                    
                    runStart = nil
                }
            }
        }

        // ── Pass 3: Draw current-line highlight + line numbers ──
        for (i, f) in frags.enumerated() {
            let isCurrentFragment = curFragGlyphRange != nil
                && NSIntersectionRange(f.fragGlyphRange, curFragGlyphRange!).length > 0
            let isSelected = selFragIndices.contains(i)

            // ── Current line highlight: flat rect, full gutter width (not rounded) ──
            //    Only when no multi-line selection is active, or this is the caret line
            if isCurrentFragment, let hlColor = lineHighlightColor, !hasSelection {
                let hlRect = NSRect(x: 0, y: f.screenY, width: gutterW, height: f.height)
                hlColor.setFill()
                hlRect.fill()

                // Top/bottom border on current line (gutter style)
                if let borderColor = separatorColor {
                    let topBorder = NSRect(x: 0, y: f.screenY, width: gutterW, height: 1)
                    borderColor.withAlphaComponent(0.4).setFill()
                    topBorder.fill()
                    let botBorder = NSRect(x: 0, y: f.screenY + f.height - 1, width: gutterW, height: 1)
                    botBorder.fill()
                }
            }

            // ── Fold toggles (first fragment only) ──
            if f.isFirstOfPara {
                let foldCX = foldGutterWidth / 2
                for region in foldRegions {
                    guard region.startLine >= 0 else { continue }
                    let lineStart = lineStartIndex(line: region.startLine, in: nsString)
                    if lineStart >= f.fragCharRange.location && lineStart < NSMaxRange(f.fragCharRange) {
                        let cy = f.screenY + f.height / 2
                        let isCollapsed = foldState?.isFolded(region) ?? false
                        drawFoldTriangle(centerX: foldCX, centerY: cy, collapsed: isCollapsed)
                    }
                }
            }

            // ── Line number (or middle dot for wrapped continuation) ──
            let displayText: String
            if f.isFirstOfPara {
                displayText = String(f.paraLineNumber)
            } else {
                displayText = "·"   // TextMate-style middle dot for wrapped lines
            }

            let numColor: NSColor
            if isSelected {
                numColor = selectionForeground
            } else if isCurrentFragment && !hasSelection {
                numColor = NSColor.labelColor
            } else {
                numColor = textColor.withAlphaComponent(f.isFirstOfPara ? 0.65 : 0.35)
            }

            let numAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: numColor]
            let size = displayText.size(withAttributes: numAttrs)
            let textRect = NSRect(x: numberRight - size.width,
                                  y: f.screenY + (f.height - size.height) / 2,
                                  width: size.width, height: size.height)
            displayText.draw(in: textRect, withAttributes: numAttrs)
        }

        // ── Pass 4: Indent guide markers (dashed lines at 4-space stops) ──
        if !hasSelection {
            let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
            if spaceWidth > 0 {
            let indentStop: CGFloat = spaceWidth * 4  // one tab stop

            let guideColor = textColor.withAlphaComponent(0.12)
            for f in frags where f.isFirstOfPara {
                let line = nsString.safeLineRange(for: f.fragCharRange)
                guard line.length > 0 else { continue }
                let lineStr = nsString.substring(with: line)
                let leading = lineStr.prefix(while: { $0 == " " || $0 == "\t" }).count
                let levels = leading / 4
                guard levels > 0 else { continue }

                for level in 1...min(levels, 15) {
                    let x = numberRight + CGFloat(level) * indentStop
                    guard x < bounds.width - 2 else { break }
                    let dashHeight: CGFloat = 1.5
                    let dashGap: CGFloat = 4
                    var y = f.screenY
                    let endY = f.screenY + f.height
                    while y + dashHeight < endY {
                        let dashRect = NSRect(x: x - 0.25, y: y, width: 0.5, height: dashHeight)
                        guideColor.setFill()
                        dashRect.fill()
                        y += dashHeight + dashGap
                    }
                }
            }
            }
        }

        // ── Vertical separator at right edge ──
        if let sepColor = separatorColor {
            let sepX = bounds.width - 0.5
            let sepPath = NSBezierPath()
            sepPath.move(to: NSPoint(x: sepX, y: dirtyRect.minY))
            sepPath.line(to: NSPoint(x: sepX, y: dirtyRect.maxY))
            sepPath.lineWidth = 1.0
            sepColor.setStroke()
            sepPath.stroke()
        }
    }

    // MARK: - Fold Triangle Drawing

    private func drawFoldTriangle(centerX: CGFloat, centerY: CGFloat, collapsed: Bool) {
        let s = triangleSize * 0.5
        let path = NSBezierPath()
        if collapsed {
            path.move(to: NSPoint(x: centerX - s * 0.4, y: centerY - s))
            path.line(to: NSPoint(x: centerX + s * 0.8, y: centerY))
            path.line(to: NSPoint(x: centerX - s * 0.4, y: centerY + s))
        } else {
            path.move(to: NSPoint(x: centerX - s, y: centerY + s * 0.5))
            path.line(to: NSPoint(x: centerX,     y: centerY - s * 0.8))
            path.line(to: NSPoint(x: centerX + s, y: centerY + s * 0.5))
        }
        path.close()
        foldToggleColor.setFill()
        path.fill()
    }

    // MARK: - Mouse Clicks

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < foldGutterWidth + 4 else { return }

        let nsString = textView.string as NSString
        let scrollOffset = scrollView?.contentView.bounds.origin.y ?? 0
        let inset = textView.textContainerInset

        var lineToChar: [Int] = []
        var ci = 0
        while ci < nsString.length {
            lineToChar.append(ci)
            let lr = nsString.safeLineRange(for: NSRange(location: ci, length: 0))
            ci = NSMaxRange(lr)
        }

        for region in foldRegions {
            guard region.startLine < lineToChar.count else { continue }
            let startChar = lineToChar[region.startLine]
            let glyphIndex = Int(SafeGlyphIndexForCharacter(layoutManager, UInt(startChar)))
            guard glyphIndex != NSNotFound,
                  glyphIndex < layoutManager.numberOfGlyphs else { continue }
            let lineRect = SafeLineFragmentRect(layoutManager, UInt(glyphIndex), nil)
            let screenY = lineRect.minY + lineRect.height / 2 + inset.height - scrollOffset

            if abs(point.y - screenY) < triangleSize + 4 {
                onFoldToggle?(region)
                return
            }
        }
    }
    
    // MARK: - Safe NSString.lineRange shim
    
    // MARK: - Utilities

    private func lineStartIndex(line: Int, in string: NSString) -> Int {
        var currentLine = 0
        var pos = 0
        while pos < string.length && currentLine < line {
            let lr = string.safeLineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(lr)
            currentLine += 1
        }
        return pos
    }

    private func lineNumberForCharacter(at index: Int, in string: NSString) -> Int {
        var lineCount = 1
        var pos = 0
        while pos < index && pos < string.length {
            let lineRange = string.safeLineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(lineRange)
            if pos <= index { lineCount += 1 }
        }
        return lineCount
    }
}