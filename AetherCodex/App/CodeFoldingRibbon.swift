import Cocoa
import CSafeLayout

// MARK: - Fold State Manager

/// Manages which fold regions are currently collapsed.
/// Stores the original text of folded regions so they can be restored.
final class FoldState {
    private(set) var foldedRegions: Set<FoldRegion> = []
    /// Cached original text for each folded region (by startLine).
    private var foldCache: [Int: String] = [:]

    var isEmpty: Bool { foldedRegions.isEmpty }

    func isFolded(_ region: FoldRegion) -> Bool {
        foldedRegions.contains(region)
    }

    func fold(_ region: FoldRegion, in textStorage: NSTextStorage) {
        guard !foldedRegions.contains(region) else { return }
        let nsText = textStorage.string as NSString
        let endLineRange = nsText.safeLineRange(for: NSRange(location: region.closeCharIndex, length: 0))

        // Range to fold: from start of START line's next line to end of END line
        let startLineRange = nsText.safeLineRange(for: NSRange(location: region.openCharIndex, length: 0))
        let foldStart = NSMaxRange(startLineRange)
        let foldEnd = NSMaxRange(endLineRange)
        let foldRange = NSRange(location: foldStart, length: max(0, foldEnd - foldStart))

        guard foldRange.length > 0 else { return }

        // Cache original text
        let original = nsText.substring(with: foldRange)
        foldCache[region.startLine] = original

        // Replace with "…" marker
        let marker = "…\n"
        textStorage.replaceCharacters(in: foldRange, with: marker)

        foldedRegions.insert(region)
    }

    func unfold(_ region: FoldRegion, in textStorage: NSTextStorage) {
        guard let original = foldCache[region.startLine],
              foldedRegions.contains(region) else { return }

        let nsText = textStorage.string as NSString

        // Find the "…\n" marker
        let startLineRange = nsText.safeLineRange(for: NSRange(location: region.openCharIndex, length: 0))
        let foldStart = NSMaxRange(startLineRange)
        // The marker is "…\n" (2 chars)
        var markerLength = 2
        if foldStart + markerLength <= nsText.length {
            let fragment = nsText.substring(with: NSRange(location: foldStart, length: markerLength))
            if !fragment.hasPrefix("…") {
                // Try just "…" (1 char fold)
                markerLength = 1
            }
        }
        let markerRange = NSRange(location: foldStart, length: min(markerLength, nsText.length - foldStart))

        textStorage.replaceCharacters(in: markerRange, with: original)

        foldCache.removeValue(forKey: region.startLine)
        foldedRegions.remove(region)
    }

    func toggle(_ region: FoldRegion, in textStorage: NSTextStorage) {
        if isFolded(region) {
            unfold(region, in: textStorage)
        } else {
            fold(region, in: textStorage)
        }
    }

    func clear() {
        foldedRegions.removeAll()
        foldCache.removeAll()
    }
}

// MARK: - Code Folding Ribbon

/// Vertical ruler ribbon drawn between the line number ruler and the text view.
/// Shows disclosure triangles at foldable line starts.
final class CodeFoldingRibbon: NSView {

    weak var textView: NSTextView?
    var foldState: FoldState?
    var regions: [FoldRegion] = []
    var toggleColor: NSColor = .secondaryLabelColor

    private let ribbonWidth: CGFloat = 16
    private let triangleSize: CGFloat = 8

    override var intrinsicContentSize: NSSize {
        NSSize(width: ribbonWidth, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let inset = textView.textContainerInset
        let glyphRange = SafeGlyphRangeForBoundingRect(layoutManager, textView.visibleRect, textContainer)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
        guard NSMaxRange(glyphRange) <= layoutManager.numberOfGlyphs else { return }
        let charRange = SafeCharacterRangeForGlyphRange(layoutManager, glyphRange)
        guard charRange.location != NSNotFound,
              charRange.length > 0 else { return }
        let nsString = textView.string as NSString
        guard nsString.length > 0 else { return }

        // Build line→character mapping
        var lineStarts: [Int] = []
        var charIndex = 0
        while charIndex < nsString.length {
            lineStarts.append(charIndex)
            let lineRange = nsString.safeLineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(lineRange)
        }

        // Draw a toggle for each fold region that falls in the visible range
        for region in regions {
            guard region.startLine < lineStarts.count else { continue }
            let startChar = lineStarts[region.startLine]
            guard startChar >= charRange.location && startChar < NSMaxRange(charRange) else {
                continue
            }

            let glyphIndex = Int(SafeGlyphIndexForCharacter(layoutManager, UInt(startChar)))
            guard glyphIndex != NSNotFound,
                  glyphIndex < layoutManager.numberOfGlyphs else { continue }
            let lineRect = SafeLineFragmentRect(layoutManager, UInt(glyphIndex), nil)

            let centerY = lineRect.minY + lineRect.height / 2 + inset.height
            let centerX = ribbonWidth / 2

            let isCollapsed = foldState?.isFolded(region) ?? false
            drawTriangle(centerX: centerX, centerY: centerY,
                         collapsed: isCollapsed, color: toggleColor)
        }
    }

    private func drawTriangle(centerX: CGFloat, centerY: CGFloat,
                               collapsed: Bool, color: NSColor) {
        let path = NSBezierPath()
        let s = triangleSize * 0.5

        if collapsed {
            // Right-pointing triangle ▶
            path.move(to: NSPoint(x: centerX - s * 0.5, y: centerY - s))
            path.line(to: NSPoint(x: centerX + s,       y: centerY))
            path.line(to: NSPoint(x: centerX - s * 0.5, y: centerY + s))
        } else {
            // Down-pointing triangle ▼
            path.move(to: NSPoint(x: centerX - s, y: centerY + s * 0.5))
            path.line(to: NSPoint(x: centerX,     y: centerY - s))
            path.line(to: NSPoint(x: centerX + s, y: centerY + s * 0.5))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    // MARK: - Hit Testing

    override func mouseDown(with event: NSEvent) {
        guard let textView = textView,
              let foldState = foldState,
              let layoutManager = textView.layoutManager else { return }

        let point = convert(event.locationInWindow, from: nil)
        let inset = textView.textContainerInset

        let nsString = textView.string as NSString

        // Build line → character
        var lineStarts: [Int] = []
        var charIndex = 0
        while charIndex < nsString.length {
            lineStarts.append(charIndex)
            let lineRange = nsString.safeLineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(lineRange)
        }

        for region in regions {
            guard region.startLine < lineStarts.count else { continue }
            let startChar = lineStarts[region.startLine]

            let glyphIndex = Int(SafeGlyphIndexForCharacter(layoutManager, UInt(startChar)))
            guard glyphIndex != NSNotFound,
                  glyphIndex < layoutManager.numberOfGlyphs else { continue }
            let lineRect = SafeLineFragmentRect(layoutManager, UInt(glyphIndex), nil)

            let centerY = lineRect.minY + lineRect.height / 2 + inset.height

            if abs(point.y - centerY) < triangleSize + 4 {
                // Toggle this fold — defer so we don't mutate during layout
                DispatchQueue.main.async { [weak textView, weak foldState] in
                    guard let storage = textView?.textStorage else { return }
                    foldState?.toggle(region, in: storage)
                    self.needsDisplay = true
                    // Re-highlight
                    let fullRange = NSRange(location: 0, length: storage.length)
                    SyntaxOracle.shared.applyHighlighting(to: storage, range: fullRange, font: nil)
                }
                break
            }
        }
    }
}