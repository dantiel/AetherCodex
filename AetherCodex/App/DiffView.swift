import SwiftUI
import AppKit

// MARK: - Diff line model

/// Semantic kind of one line in a unified diff.
enum DiffLineKind {
    /// `diff --git`, `index`, `---`/`+++`, commit metadata, `\ No newline…`.
    case meta
    /// `@@ -a,b +c,d @@` hunk header.
    case hunk
    case context
    case add
    case remove
    /// Blank context line (carries line numbers, renders empty).
    case empty
}

/// One parsed line of a unified diff. `oldNo`/`newNo` are the 1-based line
/// numbers in the old and new file respectively (nil when a line has no number
/// on that side — added lines have no old number, removed lines no new number).
struct DiffLine: Identifiable {
    let id: Int
    let kind: DiffLineKind
    var oldNo: Int?
    var newNo: Int?
    /// Leading marker: "+", "-", " " for diff content; nil for meta/hunk.
    var sign: Character?
    /// Content: for meta/hunk the full raw line, for content lines the text
    /// *after* the leading sign.
    var text: String
    var raw: String
    /// The Crepusculum strategy paired this line with its counterpart on the
    /// other side of the change. Purely presentational — the line is still an
    /// addition or a removal; only the reading changes.
    var counterpart: Bool = false
    /// Intra-line reading of a Crepusculum pair: the text sliced into shared and
    /// changed runs. Nil in unified order (the whole line is the change) and for
    /// unpaired lines.
    var runs: [DiffSpan]? = nil
}

/// One run of characters inside a Crepusculum pair. `changed == false` is text
/// both sides share; `true` is what actually differs. Rendered as a band behind
/// the glyphs, so a one-token edit reads as one token instead of as two whole
/// lines that merely resemble each other.
struct DiffSpan: Hashable {
    let text: String
    let changed: Bool
}

/// How the unified text is read back into rows.
enum DiffStrategy: String, CaseIterable, Identifiable {
    /// Git's own order: every removal of a block, then every addition.
    case unified
    /// Twilight order: each removal is emitted together with its most similar
    /// addition, so a *modification* reads as a pair instead of as a whole
    /// removal block followed by a whole addition block. Each side keeps its
    /// original relative order, so both number columns stay monotonic — the
    /// rows are re-paired, never renumbered.
    case crepusculum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unified: return "Unified"
        case .crepusculum: return "Crepusculum"
        }
    }

    var symbol: String {
        switch self {
        case .unified: return "list.bullet.rectangle"
        case .crepusculum: return "circle.lefthalf.filled"
        }
    }
}

/// The Crepusculum reading — pairing, not re-diffing.
///
/// Two unrelated lines must never be presented as one modification, so pairing
/// is gated by token similarity: only a removal whose best addition shares
/// enough vocabulary becomes a twilight pair. Everything else keeps git's own
/// grouping.
enum DiffCrepusculum {
    /// Jaccard similarity below which nothing is paired.
    private static let pairingThreshold = 0.34

    static func transmute(_ lines: [DiffLine]) -> [DiffLine] {
        var out: [DiffLine] = []
        var block: [DiffLine] = []

        func flush() {
            defer { block = [] }
            let removals = block.filter { $0.kind == .remove }
            let additions = block.filter { $0.kind == .add }
            guard !removals.isEmpty, !additions.isEmpty else {
                out.append(contentsOf: block)
                return
            }

            var used = Set<Int>()
            var pairs: [Int: Int] = [:]
            for (ri, removal) in removals.enumerated() {
                var best = -1
                var bestScore = pairingThreshold
                for (ai, addition) in additions.enumerated() where !used.contains(ai) {
                    let score = similarity(removal.text, addition.text)
                    if score > bestScore { bestScore = score; best = ai }
                }
                if best >= 0 { pairs[ri] = best; used.insert(best) }
            }

            for (ri, removal) in removals.enumerated() {
                if let ai = pairs[ri] {
                    var r = removal; r.counterpart = true
                    var a = additions[ai]; a.counterpart = true
                    // The pair is only half the reading: the twilight shows
                    // *which characters* moved, not merely that two lines were
                    // judged to be the same thought. Both sides are sliced by
                    // the same alignment, so the changed runs correspond.
                    let reading = reading(removal: removal.text, addition: a.text)
                    r.runs = reading.removed
                    a.runs = reading.added
                    out.append(r)
                    out.append(a)
                } else {
                    out.append(removal)
                }
            }
            for (ai, addition) in additions.enumerated() where !used.contains(ai) {
                out.append(addition)
            }
        }

        for line in lines {
            if line.kind == .add || line.kind == .remove {
                block.append(line)
            } else {
                flush()
                out.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: Character reading

    /// Cut a paired modification into shared and changed character runs.
    ///
    /// Shared head and tail are peeled first — exact, cheap, and the common case
    /// is one token edited inside an otherwise identical line. What remains in
    /// the middle goes through a bounded longest-common-subsequence; past the
    /// bound it is simply marked changed, because a coarse-but-true highlight
    /// beats a stall on a pathological line.
    static func reading(removal: String, addition: String)
        -> (removed: [DiffSpan], added: [DiffSpan]) {
        let a = Array(removal)
        let b = Array(addition)

        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        let aMid = Array(a[head..<(a.count - tail)])
        let bMid = Array(b[head..<(b.count - tail)])
        var keepA = [Bool](repeating: false, count: aMid.count)
        var keepB = [Bool](repeating: false, count: bMid.count)
        for (i, j) in commonSubsequence(aMid, bMid) {
            keepA[i] = true
            keepB[j] = true
        }

        func slice(_ source: [Character], _ middle: [Character], _ keep: [Bool]) -> [DiffSpan] {
            var out: [DiffSpan] = []
            if head > 0 { out.append(DiffSpan(text: String(source[..<head]), changed: false)) }
            var buffer = ""
            var changed: Bool? = nil
            for (index, character) in middle.enumerated() {
                let isChanged = !keep[index]
                if changed == isChanged {
                    buffer.append(character)
                } else {
                    if let previous = changed, !buffer.isEmpty {
                        out.append(DiffSpan(text: buffer, changed: previous))
                    }
                    buffer = String(character)
                    changed = isChanged
                }
            }
            if let previous = changed, !buffer.isEmpty {
                out.append(DiffSpan(text: buffer, changed: previous))
            }
            if tail > 0 {
                out.append(DiffSpan(text: String(source[(source.count - tail)...]), changed: false))
            }
            return out
        }

        return (slice(a, aMid, keepA), slice(b, bMid, keepB))
    }

    /// Longest-common-subsequence alignment, bounded so a pathological line
    /// cannot turn a diff into a quadratic storm. Returns the index pairs the
    /// two sides share; every other character is a change.
    private static func commonSubsequence(_ a: [Character], _ b: [Character]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0, n * m <= 160_000 else { return [] }
        let rowStride = m + 1
        var table = [Int](repeating: 0, count: (n + 1) * rowStride)
        for i in Swift.stride(from: n - 1, through: 0, by: -1) {
            for j in Swift.stride(from: m - 1, through: 0, by: -1) {
                table[i * rowStride + j] = a[i] == b[j]
                    ? table[(i + 1) * rowStride + j + 1] + 1
                    : max(table[(i + 1) * rowStride + j], table[i * rowStride + j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[(i + 1) * rowStride + j] >= table[i * rowStride + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a)
        let y = tokens(b)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    private static func tokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        return Set(parts.map(String.init))
    }
}

/// The `@@ -319,8 +420,6 @@ struct DiffSurface: View {` envelope, read into
/// human terms. The ASCII marker itself is never shown: a hunk is a *place* in
/// two files plus the declaration that encloses it.
struct HunkRanges {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    /// Git's "function context" — the text after the closing `@@`.
    let context: String

    static func parse(_ raw: String) -> HunkRanges? {
        let parts = raw.components(separatedBy: "@@")
        guard parts.count >= 2 else { return nil }
        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1
        for token in parts[1].split(separator: " ") {
            guard let sign = token.first else { continue }
            let comps = token.dropFirst().split(separator: ",")
            guard let start = Int(comps.first ?? "") else { continue }
            let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
            if sign == "-" { oldStart = start; oldCount = count }
            if sign == "+" { newStart = start; newCount = count }
        }
        let context = parts.count > 2
            ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
            : ""
        return HunkRanges(oldStart: oldStart, oldCount: oldCount,
                          newStart: newStart, newCount: newCount, context: context)
    }

    static func label(_ start: Int, _ count: Int) -> String {
        count > 1 ? "\(start)–\(start + count - 1)" : "\(start)"
    }

    var oldLabel: String { Self.label(oldStart, oldCount) }
    var newLabel: String { Self.label(newStart, newCount) }
}

/// Parses `git diff` / `git show` unified output into numbered lines.
enum DiffParser {
    static func parse(_ diffText: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        // Content lines (`-`/`+`/` `) only carry line numbers *inside* a hunk.
        // Before the first `@@` everything is metadata (commit message, diffstat,
        // `---`/`+++` file headers), so those are never mistaken for removals.
        var inHunk = false
        let rawLines = diffText.components(separatedBy: "\n")
        for (idx, raw) in rawLines.enumerated() {
            if raw.hasPrefix("@@") {
                inHunk = true
                if let h = parseHunkHeader(raw) { oldLine = h.0; newLine = h.1 }
                result.append(DiffLine(id: idx, kind: .hunk, oldNo: nil, newNo: nil, sign: nil, text: raw, raw: raw))
            } else if raw.hasPrefix("diff --git") {
                inHunk = false
                result.append(DiffLine(id: idx, kind: .meta, oldNo: nil, newNo: nil, sign: nil, text: raw, raw: raw))
            } else if !inHunk {
                result.append(DiffLine(id: idx, kind: .meta, oldNo: nil, newNo: nil, sign: nil, text: raw, raw: raw))
            } else if raw.isEmpty {
                result.append(DiffLine(id: idx, kind: .empty, oldNo: oldLine, newNo: newLine, sign: " ", text: "", raw: raw))
                oldLine += 1; newLine += 1
            } else if raw == "\\ No newline at end of file" {
                result.append(DiffLine(id: idx, kind: .meta, oldNo: nil, newNo: nil, sign: nil, text: raw, raw: raw))
            } else {
                switch raw.first! {
                case "+":
                    result.append(DiffLine(id: idx, kind: .add, oldNo: nil, newNo: newLine, sign: "+", text: String(raw.dropFirst()), raw: raw))
                    newLine += 1
                case "-":
                    result.append(DiffLine(id: idx, kind: .remove, oldNo: oldLine, newNo: nil, sign: "-", text: String(raw.dropFirst()), raw: raw))
                    oldLine += 1
                case " ":
                    result.append(DiffLine(id: idx, kind: .context, oldNo: oldLine, newNo: newLine, sign: " ", text: String(raw.dropFirst()), raw: raw))
                    oldLine += 1; newLine += 1
                default:
                    result.append(DiffLine(id: idx, kind: .meta, oldNo: nil, newNo: nil, sign: nil, text: raw, raw: raw))
                }
            }
        }
        return result
    }

    /// `@@ -1,4 +1,5 @@` → (oldStart, newStart). The start numbers refer to the
    /// first *context* line of the hunk; the line-number counters are primed from
    /// them and then advanced per line, which reproduces the numbers git prints.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        var oldStart: Int?
        var newStart: Int?
        for comp in line.components(separatedBy: " ") {
            if comp.hasPrefix("-"), let n = startNumber(comp) { oldStart = n }
            else if comp.hasPrefix("+"), let n = startNumber(comp) { newStart = n }
        }
        if let o = oldStart, let n = newStart { return (o, n) }
        return nil
    }

    private static func startNumber(_ token: String) -> Int? {
        guard let first = token.dropFirst().split(separator: ",").first else { return nil }
        return Int(first)
    }

    /// Split parsed lines into the preamble (commit message, file headers) and
    /// one section per hunk. A section's `id` is the index of its `@@` line,
    /// unique by construction. Built once at parse time: rebuilding this per
    /// scroll tick would be O(document).
    static func sectionize(_ lines: [DiffLine])
        -> (preamble: [DiffLine], sections: [DiffSection]) {
        var preamble: [DiffLine] = []
        var sections: [DiffSection] = []
        var rows: [DiffLine] = []
        var header: DiffLine?

        var headerPosition = 0

        func flush() {
            if let header {
                sections.append(DiffSection(id: header.id, header: header, rows: rows,
                                            ranges: HunkRanges.parse(header.raw),
                                            position: headerPosition))
            }
            rows = []
        }

        for (position, line) in lines.enumerated() {
            if line.kind == .hunk {
                flush()
                header = line
                headerPosition = position
            } else if header == nil {
                preamble.append(line)
            } else {
                rows.append(line)
            }
        }
        flush()
        return (preamble, sections)
    }
}

/// One hunk: its `@@` header plus the rows it covers. The header is the line the
/// diff surface pins under the top safe-area bar while the hunk is being read.
struct DiffSection: Identifiable {
    let id: Int
    let header: DiffLine
    let rows: [DiffLine]
    let ranges: HunkRanges?
    /// Index of the band in the *rendered* line array. Crepusculum re-pairs rows,
    /// so `id` (the parse index) no longer tracks a position — this does.
    let position: Int

    var addedCount: Int { rows.lazy.filter { $0.kind == .add }.count }
    var removedCount: Int { rows.lazy.filter { $0.kind == .remove }.count }
}

// MARK: - Document

/// State for one diff opened as a first-class tab. The view renders the parsed
/// `lines`; the raw unified text is retained for the editable "raw" mode and for
/// copying back out to the clipboard.
final class DiffDocument: ObservableObject {
    @Published var title: String
    @Published var subtitle: String
    @Published var lines: [DiffLine] = []
    /// Lines split once into the preamble and one section per hunk, so the
    /// surface can render `@@` headers as pinned glass bands without re-walking
    /// the document on every scroll tick.
    private(set) var preamble: [DiffLine] = []
    private(set) var sections: [DiffSection] = []
    @Published var rawText: String = ""
    /// Which reading of the same unified text is shown. Switching re-reads the
    /// retained `rawText` — the file on disk is never touched.
    @Published var strategy: DiffStrategy = .unified {
        didSet { if strategy != oldValue { rebuild() } }
    }
    /// The file this diff concerns (nil for commit diffs that span many files).
    /// Drives the "open in external editor" handoff.
    let filePath: URL?
    /// Repository root — lets external-editor detection honour local `core.editor`.
    let repoRoot: URL?

    init(title: String, subtitle: String = "", diff: String, filePath: URL? = nil, repoRoot: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.rawText = diff
        self.filePath = filePath
        self.repoRoot = repoRoot
        self.lines = []
        rebuild()
    }

    /// Re-reads `rawText` under the active strategy. Both readings share the
    /// parser; only the order inside a change block differs.
    private func rebuild() {
        let parsed = DiffParser.parse(rawText)
        lines = strategy == .crepusculum ? DiffCrepusculum.transmute(parsed) : parsed
        let split = DiffParser.sectionize(lines)
        preamble = split.preamble
        sections = split.sections
    }

    var addedCount: Int { lines.lazy.filter { $0.kind == .add }.count }
    var removedCount: Int { lines.lazy.filter { $0.kind == .remove }.count }
    var hunkCount: Int { lines.lazy.filter { $0.kind == .hunk }.count }
    var maxOldLine: Int { lines.lazy.compactMap(\.oldNo).max() ?? 1 }
    var maxNewLine: Int { lines.lazy.compactMap(\.newNo).max() ?? 1 }
}

// MARK: - Tab

/// A diff opened beside file tabs. Unlike a file tab it owns no
/// `EditorViewController`; the unified diff is a SwiftUI surface.
final class DiffTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    let document: DiffDocument

    init(title: String, subtitle: String = "", diff: String, filePath: URL? = nil, repoRoot: URL? = nil) {
        self.title = title
        self.document = DiffDocument(title: title, subtitle: subtitle, diff: diff,
                                    filePath: filePath, repoRoot: repoRoot)
    }
}

// MARK: - Surface

/// A unified diff rendered in the main editor area: two line-number columns
/// (old on the left, new beside it) plus a single unified content column. The
/// content is selectable and, via the Edit toggle, editable as the raw diff.
struct DiffSurface: View {
    @ObservedObject var document: DiffDocument
    let theme: SyntaxTheme
    /// Extra chrome height above the surface (the editor tab strip).
    var topInset: CGFloat = 0
    /// Sidebar chrome widths to indent past — mirrors the code surface so the
    /// diff content clears the leading sidebar and stops before the trailing
    /// Pythia inspector instead of painting underneath them.
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    @State private var isEditing = false
    /// Vertical scroll offset of the diff content. The number columns are pinned
    /// chrome (they never travel sideways); this offset is the only thing that
    /// moves them, so they stay locked to the rows they number.
    @State private var scrollOffset: CGPoint = .zero
    /// Index of the hunk currently under the read line — drives the counter and
    /// the prev/next steps.
    @State private var currentHunk: Int = 0

    // Metrics
    private var monoFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private var monoSwiftUIFont: Font { .system(size: 12, design: .monospaced) }
    private var lineHeight: CGFloat { EditorGutterStyle.measuredLineHeight(for: monoFont, lineSpacing: 0) + 2 }

    /// Width of one number column for a side whose largest line is `maxLine`.
    /// The only formula in this file: the pinned column, its number offsets and
    /// the chrome alignment all read it, so they cannot drift apart.
    static func numberColumnWidth(maxLine: Int) -> CGFloat {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: mono]).width
        return CGFloat(max(2, String(max(1, maxLine)).count)) * charWidth + 18
    }

    private var oldColWidth: CGFloat { Self.numberColumnWidth(maxLine: document.maxOldLine) }
    private var newColWidth: CGFloat { Self.numberColumnWidth(maxLine: document.maxNewLine) }
    private let signColWidth: CGFloat = 16
    /// Left breathing room before the old-number column — the diff's echo of
    /// `EditorGutterStyle.numberLeftPadding`.
    private static let numberLeftPadding: CGFloat = 12
    /// Gap between a number and its column's trailing edge.
    private static let numberTrailingGap: CGFloat = 6

    /// The diff's pinned leading column — what `gutter.width` is to the code
    /// surface. Both number columns, sized by the digits of the largest number on
    /// either side. The sign column travels with the text (only the gutter is
    /// fixed), so it is deliberately not part of this span.
    private var gutterWidth: CGFloat { Self.leadingGutterWidth(for: document) }

    /// Leading column span of the unified diff. Shared with the window chrome so
    /// the title and the tab strip start past the numbers — and keep doing so as
    /// the digit count grows.
    static func leadingGutterWidth(for document: DiffDocument) -> CGFloat {
        numberLeftPadding + numberColumnWidth(maxLine: document.maxOldLine)
            + numberColumnWidth(maxLine: document.maxNewLine)
    }

    /// Trailing edge of the old-number column, before the trailing gap.
    private var oldColumnMaxX: CGFloat { Self.numberLeftPadding + oldColWidth }

    /// The code gutter's own ruler face, so both surfaces number with the same
    /// typography instead of two unrelated sizes.
    private var rulerFont: NSFont {
        EditorGutterStyle.rulerFont(for: SyntaxOracle.shared.baseFont,
                                    pinnedSize: theme.rulerFontSize)
    }

    private var accent: Color { Color(nsColor: theme.sidebarAccent) }
    private var foreground: Color { Color(nsColor: theme.editorForeground) }
    private var addColor: Color { Color(nsColor: .systemGreen) }
    private var removeColor: Color { Color(nsColor: .systemRed) }
    private var separatorColor: Color { Color(nsColor: theme.rulerSeparator) }

    var body: some View {
        GeometryReader { proxy in
            // The safe-area bar carries the diff's own command row below the
            // title/tab band, so the bar — and the line the pinned hunk bands
            // dock to — grow by exactly that row.
            let topEdgeHeight = EditorChromeMetrics.scrollEdgeBarHeight(topInset: topInset)
            let dockLine = topEdgeHeight + Self.commandBarHeight
            let contentTop: CGFloat = 16
            ZStack(alignment: .topLeading) {
                // The editor field begins where the text begins — past the band
                // and the number columns. Painted across the window it became a
                // second, opaque surface beneath the band's glass, which is what
                // made the sidebar region read as its own pane instead of as the
                // tail of one continuous column.
                theme.editorBackgroundColor
                    .frame(width: max(proxy.size.width - (isEditing ? 0 : leading + gutterWidth), 1),
                           height: proxy.size.height)
                    .offset(x: isEditing ? 0 : leading + gutterWidth)

                if isEditing {
                    rawEditor(topEdgeHeight: topEdgeHeight)
                } else {
                    diffScroll(topEdgeHeight: topEdgeHeight,
                               dockLine: dockLine,
                               contentTop: contentTop)
                }

                if !isEditing {
                    // ONE surface, the code surface's own recipe: sidebar band +
                    // both number columns as one glass, one pigment, one fade,
                    // with the divider under the same mask.
                    LeadingChromeColumn(
                        leading: leading,
                        width: gutterWidth,
                        height: proxy.size.height,
                        color: theme.rulerBackground,
                        opacity: Double(ThemeSettings.shared.resolvedRulerBackgroundOpacity(for: theme)),
                        separator: theme.rulerSeparator
                    ) {
                        DiffGutterNumbers(lines: document.lines,
                                          lineHeight: lineHeight,
                                          verticalOffset: dockLine + contentTop - scrollOffset.y,
                                          oldColumnMaxX: oldColumnMaxX,
                                          newColumnMaxX: gutterWidth,
                                          trailingGap: Self.numberTrailingGap,
                                          fontSize: rulerFont.pointSize,
                                          numberColor: theme.rulerForeground,
                                          addBand: addColor.opacity(0.10),
                                          removeBand: removeColor.opacity(0.10),
                                          pairBand: accent.opacity(0.06))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    // MARK: Layers

    private func diffScroll(topEdgeHeight: CGFloat, dockLine: CGFloat,
                            contentTop: CGFloat) -> some View {
        // Same nesting as the code surface: horizontal on the outside, vertical
        // inside. The pinned number columns are *not* part of this scroll — they
        // are chrome, so the text slides beneath them instead of dragging them
        // sideways.
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: true) {
                ScrollView(.vertical, showsIndicators: true) {
                    // Every hunk is a section; its band is the section header, so
                    // the hunk under the command row docks there and reads as that
                    // row growing by one line while its rows scroll beneath it.
                    LazyVStack(alignment: .leading, spacing: 0,
                               pinnedViews: [.sectionHeaders]) {
                        ForEach(document.preamble) { line in
                            row(line)
                        }
                        ForEach(document.sections) { section in
                            Section {
                                ForEach(section.rows) { line in
                                    row(line)
                                }
                            } header: {
                                ParallaxHunkHeader(section: section,
                                                   theme: theme,
                                                   height: lineHeight,
                                                   dockLine: dockLine,
                                                   coordinateSpace: Self.scrollSpace)
                                    .id(section.id)
                            }
                        }
                    }
                    .padding(.leading, leading + gutterWidth)
                    .padding(.trailing, trailing + 24)
                    .padding(.top, contentTop)
                    .padding(.bottom, 40)
                }
                .coordinateSpace(name: Self.scrollSpace)
                // The code view's native edge effect: scrolled rows frost as they
                // pass under the bar, while the pigment behind the scroll view never
                // blurs. The bar below reserves title band + command row, so the
                // frost ramps over both.
                .scrollEdgeEffectStyle(.soft, for: [.top])
                .scrollEdgeEffectHidden(false, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    topBar(topEdgeHeight: topEdgeHeight, scroller: scroller)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
                } action: { _, newOffset in
                    scrollOffset.y = newOffset
                    currentHunk = hunkIndex(at: newOffset, contentTop: contentTop)
                }
                .contentMargins(.leading, leading + gutterWidth, for: .scrollIndicators)
            }
            .contentMargins(.trailing, trailing + 24, for: .scrollIndicators)
            .scrollIndicators(.visible)
        }
    }

    private func row(_ line: DiffLine) -> some View {
        DiffRow(line: line, theme: theme, signColWidth: signColWidth,
                font: monoSwiftUIFont, lineHeight: lineHeight)
    }

    private static let scrollSpace = "diff-scroll"
    /// Height of the diff's own command row under the title/tab band.
    private static let commandBarHeight: CGFloat = 32

    /// The top bar: the title/tab band's blur placeholder **plus** the diff's
    /// command row, declared as one bar. That is what extends the progressive
    /// blur over the command row and what moves the content — and the dock line
    /// of the pinned hunk bands — down by its height.
    private func topBar(topEdgeHeight: CGFloat, scroller: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            CodeScrollEdgeBar(height: topEdgeHeight)
            commandBar(scroller: scroller)
        }
    }

    /// The diff's controls, docked in the bar instead of floating over the code.
    /// No file name: the title and the tab already carry it.
    private func commandBar(scroller: ScrollViewProxy) -> some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(DiffStrategy.allCases) { strategy in
                    Button {
                        document.strategy = strategy
                        currentHunk = 0
                    } label: {
                        Label(strategy.label, systemImage: strategy.symbol)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: document.strategy.symbol)
                        .font(.system(size: 10, weight: .medium))
                    Text(document.strategy.label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Diff strategy")

            marker

            Text("+\(document.addedCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(addColor)
            Text("−\(document.removedCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(removeColor)

            if !document.sections.isEmpty {
                marker
                Button { jump(-1, scroller: scroller) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .disabled(currentHunk <= 0)
                .help("Previous hunk")

                Text("\(min(currentHunk + 1, document.sections.count))/\(document.sections.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32)

                Button { jump(1, scroller: scroller) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .disabled(currentHunk >= document.sections.count - 1)
                .help("Next hunk")
            }

            Spacer(minLength: 6)

            Button { copyRaw() } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .help("Copy unified diff")

            if let filePath = document.filePath {
                Button { openExternally(filePath) } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                }
                .help("Open in external editor")
            }

            Button { isEditing = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
            }
            .help("Edit raw diff")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.leading, leading + gutterWidth + 10)
        .padding(.trailing, trailing + 14)
        .frame(height: Self.commandBarHeight)
    }

    private var marker: some View {
        Rectangle()
            .fill(Color(nsColor: theme.rulerSeparator).opacity(0.5))
            .frame(width: 1, height: 12)
    }

    /// Step to the neighbouring hunk. The band docks at the top of the read
    /// area, i.e. directly under the command row.
    private func jump(_ delta: Int, scroller: ScrollViewProxy) {
        guard !document.sections.isEmpty else { return }
        let target = min(max(currentHunk + delta, 0), document.sections.count - 1)
        currentHunk = target
        withAnimation(.easeOut(duration: 0.22)) {
            scroller.scrollTo(document.sections[target].id, anchor: .top)
        }
    }

    /// Index of the hunk whose band has passed the read line. Rows share one
    /// uniform pitch, so this is arithmetic — no layout pass.
    private func hunkIndex(at offset: CGFloat, contentTop: CGFloat) -> Int {
        guard !document.sections.isEmpty else { return 0 }
        let y = offset - contentTop + lineHeight * 0.5
        var index = 0
        for (i, section) in document.sections.enumerated()
        where CGFloat(section.position) * lineHeight <= y {
            index = i
        }
        return index
    }

    /// Raw-diff editing. Kept out of the command bar's mode switch: here the bar
    /// is gone, so the way back is an explicit control.
    private func rawEditor(topEdgeHeight: CGFloat) -> some View {
        TextEditor(text: $document.rawText)
            .font(monoSwiftUIFont)
            .foregroundStyle(foreground)
            .scrollContentBackground(.hidden)
            .padding(.top, topEdgeHeight + Self.commandBarHeight + 8)
            .padding(.bottom, 24)
            .padding(.leading, leading)
            .padding(.trailing, trailing + 20)
            .overlay(alignment: .topTrailing) {
                Button { isEditing = false } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Done editing")
                .padding(.top, topEdgeHeight + 8)
                .padding(.trailing, trailing + 14)
            }
    }

    private func copyRaw() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(document.rawText, forType: .string)
    }

    private func openExternally(_ fileURL: URL) {
        ExternalEditorResolver.open(fileURL: fileURL, repoRoot: document.repoRoot)
    }
}

// MARK: - Row

private struct DiffRow: View {
    let line: DiffLine
    let theme: SyntaxTheme
    let signColWidth: CGFloat
    let font: Font
    let lineHeight: CGFloat

    private var accent: Color { Color(nsColor: theme.sidebarAccent) }
    private var foreground: Color { Color(nsColor: theme.editorForeground) }
    private var addColor: Color { Color(nsColor: .systemGreen) }
    private var removeColor: Color { Color(nsColor: .systemRed) }

    var body: some View {
        HStack(spacing: 0) {
            signCell
            contentCell
        }
        .frame(height: lineHeight, alignment: .top)
        .background(rowBackground)
        // Crepusculum marks the pair, not the line: a rail down the two rows that
        // were read as one modification. Unified leaves it invisible.
        .overlay(alignment: .leading) {
            if line.counterpart {
                Rectangle()
                    .fill(accent.opacity(0.55))
                    .frame(width: 2)
            }
        }
    }

    @ViewBuilder private var signCell: some View {
        Text(line.sign.map(String.init) ?? "")
            .font(font)
            .foregroundStyle(signColor)
            .frame(width: signColWidth, height: lineHeight, alignment: .topLeading)
    }

    private var contentCell: some View {
        Text(attributedContent)
            .font(font)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 12)
    }

    /// The row as one attributed run: the sign in its own pigment, then the
    /// body. In Crepusculum the body arrives already sliced into shared and
    /// changed runs, and only the changed ones carry a band — that is the whole
    /// point of the twilight reading: the token that moved glows, the rest of
    /// the line stays quiet so the eye never re-reads what it already knows.
    private var attributedContent: AttributedString {
        var out = AttributedString()
        if let sign = line.sign {
            var glyph = AttributedString(String(sign))
            glyph.foregroundColor = signColor
            out += glyph
        }
        if let runs = line.runs, !runs.isEmpty {
            for run in runs {
                var piece = AttributedString(run.text)
                piece.foregroundColor = run.changed ? contentColor : contentColor.opacity(0.62)
                if run.changed { piece.backgroundColor = changedBackground }
                out += piece
            }
        } else {
            var body = AttributedString(line.text)
            body.foregroundColor = contentColor
            out += body
        }
        if out.characters.isEmpty {
            var space = AttributedString(" ")
            space.foregroundColor = contentColor.opacity(0)
            out += space
        }
        return out
    }

    /// Band behind a changed run — stronger than the row wash, so the eye lands
    /// on the characters rather than on the line.
    private var changedBackground: Color {
        switch line.kind {
        case .add: return addColor.opacity(0.30)
        case .remove: return removeColor.opacity(0.28)
        default: return accent.opacity(0.18)
        }
    }

    // MARK: Styling

    private var signColor: Color {
        switch line.kind {
        case .add: return addColor
        case .remove: return removeColor
        case .hunk: return accent
        default: return foreground.opacity(0.7)
        }
    }

    private var contentColor: Color {
        switch line.kind {
        case .add: return addColor
        case .remove: return removeColor
        case .hunk: return accent
        case .meta: return foreground.opacity(0.58)
        case .empty: return foreground.opacity(0.35)
        default: return foreground
        }
    }


    private var rowBackground: Color {
        switch line.kind {
        case .add: return addColor.opacity(0.10)
        case .remove: return removeColor.opacity(0.10)
        case .hunk: return accent.opacity(0.10)
        case .meta: return foreground.opacity(0.04)
        default: return .clear
        }
    }
}

// MARK: - Hunk header

/// One hunk as a glass band — never the raw `@@ -a,b +c,d @@` line.
///
/// A hunk is a *place* in two files plus the declaration that encloses it, so the
/// band shows exactly that: the old range, a hinge, the new range, and git's
/// function context ("struct DiffSurface: View {"). The ASCII marker is
/// transport, not information.
///
/// The band scrolls with its hunk until the top bar takes it: then the section
/// header pins flush under the command row and, being the same glass and the
/// same accent pigment as the bar above it, reads as that bar growing by one row
/// instead of as a second surface floating over the code. Glass (not paint) is
/// what keeps the row it covers legible while it is docked.
///
/// Parallax: before docking, the band eases a few points against the travel of
/// its rows and settles to zero exactly at the dock line, so it arrives soft and
/// latches without a jump. The offset is purely visual — it never moves layout,
/// so the number columns stay locked to their rows.
private struct ParallaxHunkHeader: View {
    let section: DiffSection
    let theme: SyntaxTheme
    let height: CGFloat
    /// Lower edge of the top bar (title band + command row), in scroll space.
    let dockLine: CGFloat
    let coordinateSpace: String

    var body: some View {
        GeometryReader { geo in
            let distance = geo.frame(in: .named(coordinateSpace)).minY - dockLine
            let lag = min(max(distance, 0), height * 3) * 0.12
            HunkHeaderBand(section: section, theme: theme, height: height)
                .offset(y: -lag)
        }
        .frame(height: height)
    }
}

private struct HunkHeaderBand: View {
    let section: DiffSection
    let theme: SyntaxTheme
    let height: CGFloat

    private var accent: Color { Color(nsColor: theme.sidebarAccent) }
    private var separator: Color { Color(nsColor: theme.rulerSeparator) }
    private var foreground: Color { Color(nsColor: theme.editorForeground) }
    private var addColor: Color { Color(nsColor: .systemGreen) }
    private var removeColor: Color { Color(nsColor: .systemRed) }

    var body: some View {
        HStack(spacing: 8) {
            if let ranges = section.ranges {
                HStack(spacing: 5) {
                    Text(ranges.oldLabel)
                        .foregroundStyle(foreground.opacity(0.55))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(foreground.opacity(0.28))
                    Text(ranges.newLabel)
                        .foregroundStyle(accent)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }

            if let context = section.ranges?.context, !context.isEmpty {
                Rectangle()
                    .fill(separator.opacity(0.5))
                    .frame(width: 1, height: 11)
                Text(context)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(foreground.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if section.addedCount > 0 {
                Text("+\(section.addedCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(addColor.opacity(0.9))
            }
            if section.removedCount > 0 {
                Text("−\(section.removedCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(removeColor.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background {
            Rectangle()
                .fill(.clear)
                .pigmentedGlass(tint: accent.opacity(0.10), in: Rectangle())
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(separator.opacity(0.6))
                .frame(height: 0.5)
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let ranges = section.ranges else { return "Hunk" }
        let context = ranges.context.isEmpty ? "" : ", \(ranges.context)"
        return "Hunk, line \(ranges.oldLabel) to \(ranges.newLabel)\(context)"
    }
}

// MARK: - Pinned number columns

/// Draws both line-number streams for the visible rows only, offset by the live
/// scroll position. Unlike the rows themselves this layer never scrolls
/// sideways — the columns are chrome, so the diff text travels beneath them
/// exactly as code travels beneath the code gutter.
///
/// The sharp layer is masked with the code gutter's own ramp (invisible through
/// the title band, arriving soft below it); a blurred copy sits in the ramp's
/// middle band, which is what makes it read as a progressive blur rather than a
/// plain opacity fade.
private struct DiffGutterNumbers: View {
    let lines: [DiffLine]
    let lineHeight: CGFloat
    /// y of row 0 in view coordinates (already minus the scroll offset).
    let verticalOffset: CGFloat
    /// Trailing x of the old-number column (numbers are right-aligned here).
    let oldColumnMaxX: CGFloat
    /// Trailing x of the new-number column.
    let newColumnMaxX: CGFloat
    let trailingGap: CGFloat
    let fontSize: CGFloat
    let numberColor: NSColor
    let addBand: Color
    let removeBand: Color
    /// Twilight tint for a Crepusculum pair; replaces the add/remove band so the
    /// two rows read as one.
    let pairBand: Color

    /// One title band plus a ramp — the same geometry as `ProgressiveGutterNumbers`.
    private let transitionHeight: CGFloat = EditorChromeMetrics.titleBarBand + 32

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
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

            canvas
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

    private var canvas: some View {
        Canvas { context, size in
            guard !lines.isEmpty, lineHeight > 0 else { return }
            let first = max(0, Int(floor((-verticalOffset) / lineHeight)))
            let last = min(lines.count - 1,
                           Int(ceil((size.height - verticalOffset) / lineHeight)))
            guard first <= last else { return }
            let font = Font.system(size: fontSize, design: .monospaced)
            let anchor = UnitPoint(x: 1, y: 0.5)
            for index in first...last {
                let row = lines[index]
                let y = verticalOffset + CGFloat(index) * lineHeight
                // The row tint continues into the number column, so an added or
                // removed line reads as one band instead of two panes.
                switch row.kind {
                case .add:
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: lineHeight)),
                                 with: .color(row.counterpart ? pairBand : addBand))
                case .remove:
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: lineHeight)),
                                 with: .color(row.counterpart ? pairBand : removeBand))
                default:
                    break
                }
                let centre = y + lineHeight / 2
                if let old = row.oldNo {
                    draw(Text("\(old)").font(font).foregroundStyle(Color(nsColor: numberColor)),
                         in: &context, at: CGPoint(x: oldColumnMaxX - trailingGap, y: centre), anchor: anchor)
                }
                if let new = row.newNo {
                    draw(Text("\(new)").font(font).foregroundStyle(Color(nsColor: numberColor)),
                         in: &context, at: CGPoint(x: newColumnMaxX - trailingGap, y: centre), anchor: anchor)
                }
            }
        }
    }

    private func draw(_ text: Text, in context: inout GraphicsContext,
                      at point: CGPoint, anchor: UnitPoint) {
        context.draw(text, at: point, anchor: anchor)
    }
}