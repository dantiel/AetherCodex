import SwiftUI
import AppKit

// MARK: - Project match

/// One project-wide hit. `range` is UTF-16 within its file's string; `line` is
/// 1-based. Drives the results list in the polymorphic find/replace dialog.
struct ProjectMatch: Identifiable {
    let id = UUID()
    let url: URL
    let line: Int
    /// 1-based UTF-16 column of the match's start within its line.
    let column: Int
    let range: NSRange
    let lineText: String
}

/// One highlighted row in the find window's results list (`.file`/`.selection`).
/// `localRange` is the match's range *within* `text`, offset past any leading
/// indentation so the highlight lands on the actual characters.
struct FindResultRow: Identifiable {
    let index: Int
    let line: Int
    let text: String
    let localRange: NSRange
    var id: Int { index }
}

// MARK: - Model

/// Single source of truth for the TextMate-style find & replace dialog.
/// Owned by `EditorViewController` (so menu items + key equivalents reach it),
/// observed by `TextKit2ScrollSurface`, which renders the bar and scroll-reveals.
///
/// The surface is *polymorphic*: the same model drives three scopes —
/// `.file`, `.selection`, `.project` — and a find-only vs find-and-replace
/// mode. The bar re-forms itself around those two axes.
@MainActor
final class FindReplaceModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case file = "In File"
        case selection = "In Selection"
        case project = "In Project"
        var id: String { rawValue }
    }

    @Published var isVisible = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var ignoreCase = true
    @Published var wholeWord = false
    @Published var regularExpression = false
    @Published var wrapAround = true
    @Published var scope: Scope = .file
    @Published private(set) var isReplaceMode = false

    @Published private(set) var matches: [QuickMatch] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var resultSummary = ""

    /// Project scope results (find-only — replace is not offered across files).
    @Published private(set) var projectMatches: [ProjectMatch] = []
    /// Project results grouped per file, streamed incrementally.
    @Published private(set) var projectFileGroups: [ProjectFileMatch] = []
    /// Non-nil when the last project search failed (e.g. invalid regex).
    @Published private(set) var projectSearchError: String? = nil
    @Published private(set) var isSearchingProject = false

    /// Display rows for the find window's list — snapshot of each match's line.
    @Published private(set) var rows: [FindResultRow] = []

    /// Line to scroll into view (1-based) + monotonically-increasing token so
    /// SwiftUI reacts even when two consecutive matches land on one line.
    @Published var pendingRevealLine: Int? = nil
    @Published var revealToken = 0

    weak var textView: NSTextView?

    /// Resolves the project root for `.project` scope; wired by the window.
    var projectRootProvider: (() -> URL?)?
    /// Opens a project result and reveals the given 1-based line.
    var openFile: ((URL, Int) -> Void)?

    private var originRange: NSRange?
    private var selectionRange: NSRange?
    private var projectSearchTask: Task<Void, Never>?

    var sourceString: String { textView?.string ?? "" }

    // MARK: - Visibility

    /// ⌘F opens find mode; ⌘⌥F opens find-and-replace mode.
    func show(replace: Bool) {
        isReplaceMode = replace
        originRange = textView?.selectedRange()
        captureSelectionIfNeeded()
        isVisible = true
        if !query.isEmpty { search() }
        AppScene.shared.presentFind(self)
    }

    /// ⌘G (next) toggles on when closed, otherwise advances.
    func toggle() {
        if isVisible { next() } else { show(replace: false) }
    }

    /// Esc — restore the pre-search selection and fold the bar away.
    func cancel() {
        guard isVisible else { return }
        isVisible = false
        if let origin = originRange, let tv = textView, NSMaxRange(origin) <= tv.string.count {
            tv.setSelectedRange(origin)
        }
        resetResults()
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }

    // MARK: - Query

    func setQuery(_ newQuery: String) {
        query = newQuery
        search()
    }

    /// ⌘E — TextMate's "Use Selection for Find": copy the selection (or the
    /// word under the caret) into the find buffer without opening the dialog.
    /// The next ⌘G then finds the following occurrence.
    func useSelectionForFind() {
        guard let tv = textView else { return }
        var sel = tv.selectedRange()
        if sel.length == 0 {
            sel = tv.selectionRange(forProposedRange: NSRange(location: sel.location, length: 0),
                                    granularity: .selectByWord)
        }
        guard sel.length > 0, sel.location < tv.string.count else { NSSound.beep(); return }
        query = (tv.string as NSString).substring(with: sel)
        regularExpression = false
        wholeWord = false
        scope = .file
        isVisible = false
        search()
    }

    // MARK: - Navigation

    func next() { ensureSearched(); step(1) }
    func previous() { ensureSearched(); step(-1) }

    // MARK: - Replace

    func replaceCurrent() {
        guard let tv = textView, currentIndex < matches.count else { return }
        let m = matches[currentIndex]
        let ns = tv.string as NSString
        guard NSMaxRange(m.range) <= ns.length else { return }

        let rep: String
        if regularExpression, let regex = currentRegex {
            let results = regex.matches(in: tv.string, options: [], range: m.range)
            rep = results.first.map {
                regex.replacementString(for: $0, in: tv.string, offset: 0, template: replacement)
            } ?? replacement
        } else {
            rep = replacement
        }

        if tv.shouldChangeText(in: m.range, replacementString: rep) {
            tv.textStorage?.replaceCharacters(in: m.range, with: rep)
            tv.didChangeText()
        }
        search()
    }

    func replaceAll() {
        guard let tv = textView else { return }
        let range = activeSearchRange()
        guard range.location != NSNotFound, NSMaxRange(range) <= (tv.string as NSString).length else { return }
        guard let newString = replacedString(in: range) else { NSSound.beep(); return }
        if tv.shouldChangeText(in: range, replacementString: newString) {
            tv.textStorage?.replaceCharacters(in: range, with: newString)
            tv.didChangeText()
        }
        search()
    }

    // MARK: - Search

    func search() {
        if scope == .project {
            searchProject()
        } else {
            searchInEditor()
        }
    }

    // MARK: - Internals

    private func resetResults() {
        matches = []
        rows = []
        currentIndex = 0
        pendingRevealLine = nil
        resultSummary = ""
    }

    private func captureSelectionIfNeeded() {
        selectionRange = (scope == .selection) ? textView?.selectedRange() : nil
    }

    private func ensureSearched() {
        if matches.isEmpty && !query.isEmpty { search() }
    }

    private func activeSearchRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: NSNotFound, length: 0) }
        let ns = tv.string as NSString
        if scope == .selection, let sel = selectionRange, sel.length > 0, NSMaxRange(sel) <= ns.length {
            return sel
        }
        return NSRange(location: 0, length: ns.length)
    }

    private var currentRegex: NSRegularExpression? {
        try? NSRegularExpression(pattern: query, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private func searchInEditor() {
        guard let tv = textView else {
            resetResults(); return
        }
        let ns = tv.string as NSString
        guard !query.isEmpty, ns.length > 0 else {
            resetResults(); return
        }
        let range = activeSearchRange()
        let found = scan(ns, in: range)
        matches = found
        currentIndex = 0
        rebuildRows(in: ns, matches: found)
        if found.isEmpty {
            pendingRevealLine = nil
            resultSummary = "No results"
            return
        }
        resultSummary = "\(found.count) matches"
        let origin = (scope == .selection ? (selectionRange?.location ?? 0) : (originRange?.location ?? 0))
        currentIndex = found.firstIndex { $0.range.location >= origin } ?? 0
        applyCurrent()
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let n = matches.count
        if wrapAround {
            currentIndex = (currentIndex + delta + n) % n
        } else {
            currentIndex = min(max(currentIndex + delta, 0), n - 1)
        }
        applyCurrent()
    }

    private func applyCurrent() {
        guard !matches.isEmpty, currentIndex < matches.count else { return }
        let m = matches[currentIndex]
        if let tv = textView, NSMaxRange(m.range) <= tv.string.count {
            tv.setSelectedRange(m.range)
        }
        pendingRevealLine = m.line
        revealToken += 1
    }

    /// Jump to the given result row (the find window's list) — selects the
    /// match in the editor and scrolls it into view without touching the query.
    func select(rowIndex: Int) {
        guard rowIndex >= 0, rowIndex < matches.count else { return }
        currentIndex = rowIndex
        applyCurrent()
    }

    /// Snapshots each match's enclosing line into a display row (bounded for
    /// very large files) so the results list renders without re-reading the
    /// text storage on every frame.
    private func rebuildRows(in ns: NSString, matches: [QuickMatch]) {
        let limit = 400
        let cap = min(matches.count, limit)
        var out: [FindResultRow] = []
        out.reserveCapacity(cap)
        var lastLineStart = -1
        var lastText = ""
        for i in 0..<cap {
            let m = matches[i]
            let loc = min(max(m.range.location, 0), max(ns.length - 1, 0))
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let text: String
            if lineRange.location == lastLineStart {
                text = lastText
            } else {
                var raw = ns.substring(with: lineRange)
                while let c = raw.last, c == "\n" || c == "\r" { raw.removeLast() }
                lastLineStart = lineRange.location
                lastText = raw
                text = raw
            }
            let lead = text.prefix { $0 == " " || $0 == "\t" }.count
            let rawLoc = m.range.location - lineRange.location - lead
            let loc2 = max(0, rawLoc)
            let len = min(max(0, m.range.length), max(0, text.count - loc2))
            out.append(FindResultRow(index: i, line: m.line, text: text,
                                     localRange: NSRange(location: loc2, length: len)))
        }
        rows = out
    }

    /// Computes the replacement string for the whole `range` (used by replaceAll).
    private func replacedString(in range: NSRange) -> String? {
        guard let tv = textView else { return nil }
        let ns = tv.string as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return nil }
        let original = ns.substring(with: range)

        if regularExpression {
            guard let regex = currentRegex else { return nil }
            return regex.stringByReplacingMatches(in: original,
                                                  options: [],
                                                  range: NSRange(location: 0, length: (original as NSString).length),
                                                  withTemplate: replacement)
        }

        let found = scan(original as NSString, in: NSRange(location: 0, length: (original as NSString).length))
        guard !found.isEmpty else { return nil }
        var buf = original as NSString
        for m in found.reversed() {
            buf = buf.replacingCharacters(in: m.range, with: replacement) as NSString
        }
        return buf as String
    }

    /// Scans `range` of `string` honoring the active literal/regex + case +
    /// whole-word options. Regex builds a temporary matcher against the full
    /// string (ranges are absolute within `string`).
    private func scan(_ string: NSString, in range: NSRange) -> [QuickMatch] {
        if regularExpression {
            guard let regex = currentRegex else {
                resultSummary = "Invalid regular expression"
                return []
            }
            let results = regex.matches(in: string as String, options: [], range: range)
            return results.map {
                QuickMatch(range: $0.range, line: Self.lineNumber(at: $0.range.location, in: string))
            }
        }

        var opts: NSString.CompareOptions = [.literal]
        if ignoreCase { opts.insert(.caseInsensitive) }
        var result: [QuickMatch] = []
        var searchRange = range
        while searchRange.length > 0 {
            let r = string.range(of: query, options: opts, range: searchRange)
            guard r.location != NSNotFound else { break }
            if wholeWord && !Self.isWholeWord(string, range: r) {
                let next = r.location + 1
                if next >= NSMaxRange(searchRange) { break }
                searchRange = NSRange(location: next, length: NSMaxRange(searchRange) - next)
                continue
            }
            result.append(QuickMatch(range: r, line: Self.lineNumber(at: r.location, in: string)))
            let next = r.location + max(r.length, 1)
            if next >= NSMaxRange(searchRange) { break }
            searchRange = NSRange(location: next, length: NSMaxRange(searchRange) - next)
        }
        return result
    }

    // MARK: - Project scope

    private func searchProject() {
        guard let root = projectRootProvider?(), !query.isEmpty else {
            projectMatches = []
            projectFileGroups = []
            resultSummary = ""
            return
        }
        projectSearchTask?.cancel()
        isSearchingProject = true
        projectMatches = []
        projectFileGroups = []
        projectSearchError = nil
        resultSummary = "Searching…"

        let q = query
        let ic = ignoreCase
        let ww = wholeWord
        let rx = regularExpression

        projectSearchTask = Task.detached(priority: .userInitiated) {
            do {
                try await runProjectSearch(
                    roots: [root],
                    query: q,
                    ignoreCase: ic,
                    wholeWord: ww,
                    regularExpression: rx,
                    onBatch: { files in
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            let matches = files.flatMap(\.matches)
                            self.projectMatches.append(contentsOf: matches)
                            self.projectFileGroups.append(contentsOf: files)
                        }
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSearchingProject = false
                    if self.projectMatches.isEmpty {
                        self.resultSummary = "No results in project"
                    } else {
                        let fileCount = Set(self.projectMatches.map(\.url.path)).count
                        self.resultSummary = "\(self.projectMatches.count) matches in \(fileCount) files"
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSearchingProject = false
                    self.projectSearchError = (error as? ProjectSearchError)?.errorDescription
                        ?? error.localizedDescription
                    self.resultSummary = "Invalid regular expression"
                }
            }
        }
    }

    // MARK: - Helpers

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

    private static func isWholeWord(_ s: NSString, range: NSRange) -> Bool {
        let before = range.location - 1
        let after = NSMaxRange(range)
        return !isWordChar(at: before, in: s) && !isWordChar(at: after, in: s)
    }

    private static func isWordChar(at index: Int, in s: NSString) -> Bool {
        guard index >= 0, index < s.length else { return false }
        let c = s.character(at: index)
        if c == 0x5F { return true } // underscore
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}


// The find & replace UI now lives in its own TextMate-style window
// (`FindReplaceWindow.swift`), not as an in-editor bar. The model above is all
// that remains here: the polymorphic search engine and its reveal/selection
// signals, which the window consumes and the editor surface scrolls into view.