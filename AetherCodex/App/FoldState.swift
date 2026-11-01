import Cocoa
import Combine

// MARK: - Fold State Manager

/// Manages which fold regions are currently collapsed, plus the current set of
/// foldable regions for the document. `ObservableObject` so the live gutter can
/// repaint when the detected regions change or a region is toggled.
final class FoldState: ObservableObject {
    @Published private(set) var foldedRegions: Set<FoldRegion> = []
    /// Detected foldable regions for the current document (0-based lines),
    /// rebuilt by `FoldDetector` whenever the document changes shape.
    @Published var regions: [FoldRegion] = []
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

        var updated = foldedRegions
        updated.insert(region)
        foldedRegions = updated
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
        var updated = foldedRegions
        updated.remove(region)
        foldedRegions = updated
    }

    func toggle(_ region: FoldRegion, in textStorage: NSTextStorage) {
        if isFolded(region) {
            unfold(region, in: textStorage)
        } else {
            fold(region, in: textStorage)
        }
    }

    func clear() {
        foldedRegions = []
        foldCache.removeAll()
    }
}