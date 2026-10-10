import Cocoa
import CSafeLayout

// MARK: - Ghost Suggestion

/// A transparent suggestion to be rendered inline after the caret.
struct GhostSuggestion {
    let text: String
    let insertionPoint: Int  // character index in the storage
}

// MARK: - Highlighting Layout Manager

/// Intercedes between NSTextStorage and NSTextContainer.
/// Draws: ghost text, inline attachments, token backgrounds.
/// V1: ghost text rendering. V2: tree-sitter scope backgrounds, animated overlays.
final class HighlightingLayoutManager: NSLayoutManager {

    /// Include the leading padding only when selection reaches this visual
    /// line's first character. A partial first line must not gain a false band.
    static func selectionCoversLeadingEdge(_ selection: NSRange, lineStart: Int) -> Bool {
        selection.location != NSNotFound && selection.length > 0
            && selection.location <= lineStart && NSMaxRange(selection) > lineStart
    }

    // MARK: - Highlighting Gate

    /// When true, skip custom drawing phases (line highlight, ghost, inline boxes, borders)
    /// so they never run during synchronous highlight attribute mutations. Super calls
    /// always execute — text is never invisible.
    var isApplyingHighlighting = false

    // MARK: - Ghost Text

    /// Current ghost suggestion — set from editor controller when completions arrive.
    var ghostSuggestion: GhostSuggestion? {
        didSet { invalidateGhostDisplay() }
    }

    var lineHighlightColor: NSColor?
    var lineHighlightBorderColor: NSColor?

    // Inline box attachments currently active (character index → attachment)
    private var inlineBoxes: [Int: InlineBoxAttachment] = [:]

    // MARK: - Ghost Drawing

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Clamp stale glyphsToShow to valid range — never bail, always draw.
        // No ensureLayout here — it causes "attempted layout while textStorage
        // is editing" when display fires mid-edit (tv.string = ..., etc.).
        guard glyphsToShow.location != NSNotFound else { return }
        let safeMax = min(NSMaxRange(glyphsToShow), numberOfGlyphs)
        let safeRange = NSRange(location: glyphsToShow.location, length: safeMax - glyphsToShow.location)
        guard safeRange.length > 0 else { return }
        super.drawGlyphs(forGlyphRange: safeRange, at: origin)
        // ── Ghost text ──
        guard !isApplyingHighlighting, let ghost = ghostSuggestion else { return }

        let ghostText = ghost.text as NSString
        let ghostRange = NSRange(location: ghost.insertionPoint, length: ghostText.length)
        guard ghostRange.upperBound <= (textStorage?.length ?? 0) else { return }

        let glyphRange = SafeGlyphRangeForCharacterRange(self, ghostRange, nil)
        guard glyphRange.length > 0 else { return }

        let ghostAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(white: 0.6, alpha: 0.30),
        ]
        let ghostString = NSAttributedString(string: ghost.text, attributes: ghostAttrs)

        let insertGlyphIndex = glyphRange.location
        var insertPoint = SafeLocationForGlyphAtIndex(self, UInt(insertGlyphIndex))
        if let tc = textContainers.first {
            insertPoint.x += tc.lineFragmentPadding
        }
        insertPoint.y += defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)) * 0.18
        ghostString.draw(at: insertPoint)
    }

    // MARK: - AppKit Entry-Point Overrides (safe guards against stale glyph tree)

    override func characterRange(forGlyphRange glyphRange: NSRange,
                                  actualGlyphRange: NSRangePointer?) -> NSRange {
        guard glyphRange.location != NSNotFound,
              NSMaxRange(glyphRange) <= numberOfGlyphs else {
            if let agrp = actualGlyphRange {
                agrp.pointee = NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: NSNotFound, length: 0)
        }
        var result = NSRange(location: NSNotFound, length: 0)
        var ag = NSRange(location: NSNotFound, length: 0)
        if !SafeCallBlock({
            result = super.characterRange(forGlyphRange: glyphRange, actualGlyphRange: &ag)
        }) {
            if let agrp = actualGlyphRange {
                agrp.pointee = NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: NSNotFound, length: 0)
        }
        if let agrp = actualGlyphRange { agrp.pointee = ag }
        return result
    }

    override func glyphRange(forCharacterRange charRange: NSRange,
                              actualCharacterRange: NSRangePointer?) -> NSRange {
        guard charRange.location != NSNotFound,
              charRange.location <= (textStorage?.length ?? 0),
              NSMaxRange(charRange) <= (textStorage?.length ?? 0) else {
            if let acrp = actualCharacterRange {
                acrp.pointee = NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: NSNotFound, length: 0)
        }
        var result = NSRange(location: NSNotFound, length: 0)
        var ac = NSRange(location: NSNotFound, length: 0)
        if !SafeCallBlock({
            result = super.glyphRange(forCharacterRange: charRange, actualCharacterRange: &ac)
        }) {
            if let acrp = actualCharacterRange {
                acrp.pointee = NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: NSNotFound, length: 0)
        }
        if let acrp = actualCharacterRange { acrp.pointee = ac }
        return result
    }

    // MARK: - Background Drawing (inline boxes)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Clamp stale glyphsToShow to valid range — never bail, always draw.
        // No ensureLayout here — it causes "attempted layout while textStorage
        // is editing" when display fires mid-edit (tv.string = ..., etc.).
        guard glyphsToShow.location != NSNotFound else { return }
        let safeMax = min(NSMaxRange(glyphsToShow), numberOfGlyphs)
        let glyphsToShowSafe = NSRange(location: glyphsToShow.location, length: safeMax - glyphsToShow.location)
        guard glyphsToShowSafe.length > 0 else { return }

        // ═══ Phase 1: Full-width current line highlight fill (behind text) ═══
        // Skip during highlighting — attribute mutations are in flight.
        var lineHighlightBorders: (top: NSRect, bottom: NSRect)? = nil
        if !isApplyingHighlighting, let hlColor = lineHighlightColor,
           let tc = textContainers.first,
           let tv = tc.textView,
           tv.string.count > 0 {
            let nsStr = tv.string as NSString
            let selRange = tv.selectedRange()
            let selLoc = selRange.location
            // During a multi-line selection the native selection band is the
            // highlight; a second caret band on the anchor line reads as wrong.
            let hasSelection = selRange.length > 0
            if !hasSelection, selLoc < (textStorage?.length ?? 0) {
                let paraRange = nsStr.safeLineRange(for: NSRange(location: selLoc, length: 0))
                let paraGlyphRange = SafeGlyphRangeForCharacterRange(self, paraRange, nil)
                if paraGlyphRange.location != NSNotFound,
                   paraGlyphRange.length > 0,
                   NSMaxRange(paraGlyphRange) <= numberOfGlyphs,
                   NSIntersectionRange(glyphsToShowSafe, paraGlyphRange).length > 0 {
                    var frags: [(y: CGFloat, h: CGFloat)] = []
                    var currentGlyph = paraGlyphRange.location
                    let maxGlyph = min(NSMaxRange(paraGlyphRange), numberOfGlyphs)
                    var loopGuard = 0
                    while currentGlyph < maxGlyph, loopGuard < 500 {
                        loopGuard += 1
                        guard currentGlyph < numberOfGlyphs else { break }
                        var fgRange = NSRange(location: 0, length: 0)
                        let fragRect = SafeLineFragmentRect(self, UInt(currentGlyph), &fgRange)
                        guard fgRange.location != NSNotFound, fgRange.length > 0 else { break }
                        if NSIntersectionRange(glyphsToShowSafe, fgRange).length > 0 {
                            frags.append((fragRect.minY, fragRect.height))
                        }
                        let next = NSMaxRange(fgRange)
                        if next <= currentGlyph { break }
                        currentGlyph = next
                    }
                    if let first = frags.first, let last = frags.last {
                        // The fragment rects are in text-container coordinates; `origin`
                        // is where that container sits in the text view, so the band lands
                        // on the same line the glyphs are drawn on (never a stale inset).
                        let combinedY = origin.y + first.y
                        let combinedH = (last.y + last.h) - first.y
                        // The adopted editor uses an unbounded container (width ==
                        // greatestFiniteMagnitude). Filling an infinitely wide rect
                        // overflows the rasteriser and collapses the band to a sliver,
                        // so span the view's real content width instead.
                        let bandWidth = max(tv.bounds.width, 1)
                        if combinedH > 0, !combinedH.isNaN, bandWidth > 0 {
                            // Unlike glyphs, the band includes the view's inset:
                            // its left edge remains flush with the gutter at x=0.
                            let insetLeft: CGFloat = 0
                            let bandRectWidth = bandWidth
                            let fullRect = NSRect(x: insetLeft, y: combinedY,
                                                  width: bandRectWidth, height: combinedH)
                            hlColor.withAlphaComponent(0.40).setFill()
                            fullRect.fill()
                            if lineHighlightBorderColor != nil {
                                lineHighlightBorders = (
                                    NSRect(x: insetLeft, y: combinedY, width: bandRectWidth, height: 1),
                                    NSRect(x: insetLeft, y: combinedY + combinedH - 1, width: bandRectWidth, height: 1)
                                )
                            }
                        }
                    }
                }
            }
        }

        // ═══ Phase 2: Text attribute backgrounds (selection, block backgrounds) ═══
        // Native selection starts at the text-container origin, leaving the
        // NSTextView inset unpainted. Extend only that missing strip, using the
        // same selected background color and live line-fragment geometry.
        if !isApplyingHighlighting, let tv = textContainers.first?.textView,
           origin.x > 0,
           let color = tv.selectedTextAttributes[.backgroundColor] as? NSColor {
            let selections = tv.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            if !selections.isEmpty {
                color.setFill()
                var glyph = glyphsToShowSafe.location
                while glyph < NSMaxRange(glyphsToShowSafe) {
                    var fragmentRange = NSRange()
                    let fragment = SafeLineFragmentRect(self, UInt(glyph), &fragmentRange)
                    guard fragmentRange.location != NSNotFound, fragmentRange.length > 0 else { break }
                    let start = characterIndexForGlyph(at: fragmentRange.location)
                    if selections.contains(where: { Self.selectionCoversLeadingEdge($0, lineStart: start) }) {
                        NSRect(x: 0, y: origin.y + fragment.minY,
                               width: origin.x, height: fragment.height).fill()
                    }
                    let next = NSMaxRange(fragmentRange)
                    guard next > glyph else { break }
                    glyph = next
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShowSafe, at: origin)

        // ═══ Phase 3: Line highlight borders (above text backgrounds) ═══
        if let borders = lineHighlightBorders,
           let borderColor = lineHighlightBorderColor {
            borderColor.setFill()
            borders.top.fill()
            borders.bottom.fill()
        }

        // ═══ Phase 4: Inline box attachment backgrounds ═══
        guard !isApplyingHighlighting, let ts = textStorage else { return }
        let charRange = SafeCharacterRangeForGlyphRange(self, glyphsToShowSafe)

        ts.enumerateAttribute(.attachment, in: charRange, options: []) { value, range, _ in
            guard value is InlineBoxAttachment else { return }
            let glyphRange = SafeGlyphRangeForCharacterRange(self, range, nil)
            guard glyphRange.length > 0 else { return }

            guard let firstContainer = textContainers.first else { return }
            let rect = SafeBoundingRectForGlyphRange(self, glyphRange, firstContainer)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0), xRadius: 6, yRadius: 6)
            NSColor.black.withAlphaComponent(0.15).setFill()
            path.fill()
        }
    }

    // MARK: - Inline Box Management

    /// Insert an inline box at a character position.
    func insertInlineBox(_ box: InlineBoxAttachment, at characterIndex: Int) {
        guard let storage = textStorage else { return }
        let attrString = NSAttributedString(attachment: box)
        storage.insert(attrString, at: characterIndex)
        inlineBoxes[characterIndex] = box
    }

    /// Remove all inline boxes from the text.
    func removeAllInlineBoxes() {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length),
                                   options: []) { value, range, _ in
            if value is InlineBoxAttachment {
                storage.deleteCharacters(in: range)
            }
        }
        inlineBoxes.removeAll()
    }

    // MARK: - Helpers

    private func invalidateGhostDisplay() {
        guard let ghost = ghostSuggestion, let storage = textStorage else { return }
        let ghostRange = NSRange(location: ghost.insertionPoint,
                                 length: min((ghost.text as NSString).length,
                                             storage.length - ghost.insertionPoint))
        guard ghostRange.length > 0 else { return }
        let glyphRange = SafeGlyphRangeForCharacterRange(self, ghostRange, nil)
        invalidateDisplay(forGlyphRange: glyphRange)
    }
}
