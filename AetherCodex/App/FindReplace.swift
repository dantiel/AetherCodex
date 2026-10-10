import SwiftUI
import AppKit

// MARK: - Project match

/// One project-wide hit. `range` is UTF-16 within its file's string; `line` is
/// 1-based. Drives the results list in the polymorphic find/replace dialog.
struct ProjectMatch: Identifiable {
    let id = UUID()
    let url: URL
    let line: Int
    let range: NSRange
    let lineText: String
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
    @Published private(set) var isSearchingProject = false

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

    /// Return in the find field — accept the current match and fold away.
    func confirm() {
        isVisible = false
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
            resultSummary = ""
            return
        }
        projectSearchTask?.cancel()
        isSearchingProject = true
        projectMatches = []
        resultSummary = "Searching…"

        let q = query
        let ic = ignoreCase
        let ww = wholeWord
        let rx = regularExpression

        projectSearchTask = Task.detached(priority: .userInitiated) {
            let results = grepProject(root: root, query: q, ignoreCase: ic, wholeWord: ww, regularExpression: rx)
            let fileCount = Set(results.map { $0.url.path }).count
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.projectMatches = results
                self.isSearchingProject = false
                self.resultSummary = results.isEmpty
                    ? "No results in project"
                    : "\(results.count) matches in \(fileCount) files"
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

// MARK: - Project grep (runs off the main actor)

/// Walks `root` and collects text-file matches. Bounded by file/match caps so a
/// huge tree can never freeze the editor. Runs detached; only the result array
/// crosses back to the main actor.
func grepProject(root: URL, query: String, ignoreCase: Bool, wholeWord: Bool, regularExpression: Bool) -> [ProjectMatch] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

    let regex: NSRegularExpression?
    if regularExpression {
        regex = try? NSRegularExpression(pattern: query, options: ignoreCase ? [.caseInsensitive] : [])
    } else {
        regex = nil
    }
    if regularExpression && regex == nil { return [] }

    let maxFiles = 500
    let maxMatches = 2000
    var filesSeen = 0
    var results: [ProjectMatch] = []

    for case let url as URL in enumerator {
        if results.count >= maxMatches || filesSeen >= maxFiles { break }
        if isSkippedProjectPath(url.path) { continue }
        guard let data = try? Data(contentsOf: url) else { continue }
        guard isTextData(data) else { continue }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { continue }

        let ns = text as NSString
        var ranges: [NSRange] = []

        if let regex {
            ranges = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { $0.range }
        } else {
            var opts: NSString.CompareOptions = [.literal]
            if ignoreCase { opts.insert(.caseInsensitive) }
            var searchRange = NSRange(location: 0, length: ns.length)
            while searchRange.length > 0 {
                let r = ns.range(of: query, options: opts, range: searchRange)
                guard r.location != NSNotFound else { break }
                if wholeWord && !grepIsWholeWord(ns, range: r) {
                    let next = r.location + 1
                    if next >= ns.length { break }
                    searchRange = NSRange(location: next, length: ns.length - next)
                    continue
                }
                ranges.append(r)
                let next = r.location + max(r.length, 1)
                if next >= ns.length { break }
                searchRange = NSRange(location: next, length: ns.length - next)
            }
        }

        guard !ranges.isEmpty else { continue }
        filesSeen += 1
        for r in ranges.prefix(100) {
            let line = grepLineNumber(at: r.location, in: ns)
            results.append(ProjectMatch(url: url, line: line, range: r, lineText: grepLineText(at: r.location, in: ns)))
            if results.count >= maxMatches { break }
        }
    }
    return results
}

private func isSkippedProjectPath(_ path: String) -> Bool {
    let skip = Set([".git", "node_modules", "Pods", "Carthage", "build", "DerivedData",
                    ".build", "vendor", ".svn", ".hg", "xcuserdata", ".idea"])
    return path.split(separator: "/").map(String.init).contains { skip.contains($0) }
}

private func isTextData(_ data: Data) -> Bool {
    !data.prefix(8192).contains(0)
}

private func grepLineNumber(at index: Int, in ns: NSString) -> Int {
    let end = min(max(index, 0), ns.length)
    var line = 1
    var i = 0
    while i < end {
        if ns.character(at: i) == 0x0A { line += 1 }
        i += 1
    }
    return line
}

private func grepLineText(at index: Int, in ns: NSString) -> String {
    var start = 0
    var end = 0
    ns.getLineStart(&start, end: &end, contentsEnd: nil, for: NSRange(location: index, length: 0))
    return ns.substring(with: NSRange(location: start, length: end - start))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func grepIsWholeWord(_ s: NSString, range: NSRange) -> Bool {
    func word(_ i: Int) -> Bool {
        guard i >= 0, i < s.length else { return false }
        let c = s.character(at: i)
        if c == 0x5F { return true }
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
    return !word(range.location - 1) && !word(NSMaxRange(range))
}

// MARK: - Bar

/// Liquid-glass find & replace bar. Polymorphic: the replace row appears only
/// in replace mode (and never for project scope); the results list appears only
/// for project scope; the scope segmented control transforms the whole behavior.
struct FindReplaceBar: View {
    @ObservedObject var model: FindReplaceModel
    @FocusState private var queryFocused: Bool
    @FocusState private var replaceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Find", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($queryFocused)
                    .onChange(of: model.query) { _, newValue in model.setQuery(newValue) }
                    .onSubmit { model.next() }

                Picker("Scope", selection: $model.scope) {
                    ForEach(FindReplaceModel.Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                .onChange(of: model.scope) { _, _ in model.search() }
            }

            if model.isReplaceMode && model.scope != .project {
                HStack(spacing: 8) {
                    TextField("Replace", text: $model.replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($replaceFocused)
                        .onSubmit { model.replaceCurrent() }

                    Button("Replace") { model.replaceCurrent() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.matches.isEmpty)

                    Button("All") { model.replaceAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.matches.isEmpty)
                }
            }

            HStack(spacing: 12) {
                optionToggle("Aa", value: $model.ignoreCase)
                optionToggle(".*", value: $model.regularExpression)
                optionToggle("W", value: $model.wholeWord)
                optionToggle("↩︎", value: $model.wrapAround)

                Spacer()

                if model.scope != .project && !model.matches.isEmpty {
                    Text("\(model.currentIndex + 1)/\(model.matches.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if model.isSearchingProject {
                    ProgressView().controlSize(.small)
                }

                Text(model.resultSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if model.scope != .project {
                    Button(action: { model.previous() }) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.matches.isEmpty)

                    Button(action: { model.next() }) {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.matches.isEmpty)
                }

                Button(action: { model.cancel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if model.scope == .project && !model.projectMatches.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.projectMatches) { match in
                            Button {
                                model.openFile?(match.url, match.line)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(match.url.lastPathComponent)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(":\(match.line)")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(match.lineText)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .frame(width: 600)
        .onChange(of: model.isVisible) { _, visible in
            if visible {
                DispatchQueue.main.async { queryFocused = true }
            } else if let tv = model.textView {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    private func optionToggle(_ label: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            model.search()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value.wrappedValue ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
