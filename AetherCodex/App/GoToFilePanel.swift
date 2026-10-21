import Cocoa
import SwiftUI

// MARK: - TextMate fuzzy ranker (ported from Frameworks/text/src/ranker.cc)
//
// This is a faithful port of TextMate 2's `oak::rank` / `calculate_rank`
// fuzzy-scoring algorithm. It produces both a score (0…1) and the matched
// character ranges used to highlight the query within a candidate path.

struct RankResult: Sendable {
    var score: Double
    var ranges: [Range<Int>]
}

enum TextMateRanker {
    /// Lowercase and strip whitespace — matches `oak::normalize_filter`.
    static func normalizeFilter(_ filter: String) -> String {
        filter.lowercased().filter { !$0.isWhitespace }
    }

    /// Subsequence check, case-insensitive (mirrors the C++ `is_subset`).
    private static func isSubset(_ needle: [Character], _ haystack: [Character]) -> Bool {
        var n = 0
        var m = 0
        while n < needle.count && m < haystack.count {
            if needle[n].lowercased() == haystack[m].lowercased() {
                n += 1
            }
            m += 1
        }
        return n == needle.count
    }

    /// Score `filter` against `candidate`. The filter should already be
    /// normalized (lowercase, no spaces). Returns score 0…1 plus the
    /// matched half-open ranges over `candidate`'s characters.
    static func rank(_ filter: String, _ candidate: String) -> RankResult {
        let f = Array(filter)
        let c = Array(candidate)
        if f.isEmpty {
            return RankResult(score: 1, ranges: [])
        }
        if !isSubset(f, c) {
            return RankResult(score: 0, ranges: [])
        }
        if f == c {
            return RankResult(score: 1, ranges: [0..<f.count])
        }
        if f.count * c.count > 8096 {
            return RankResult(score: Double(f.count) / Double(c.count), ranges: [])
        }
        return calculateRank(f, c)
    }

    private static func calculateRank(_ lhs: [Character], _ rhs: [Character]) -> RankResult {
        let n = lhs.count
        let m = rhs.count
        guard n > 0, m > 0 else { return RankResult(score: 0, ranges: []) }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: m), count: n)
        var first = [Int](repeating: m, count: n)
        var last = [Int](repeating: 0, count: n)
        var capitals = [Bool](repeating: false, count: m)

        // Precompute which candidate characters are "capitals" (word starts
        // or uppercase letters).
        var atBow = true
        for j in 0..<m {
            let ch = rhs[j]
            let isAlnum = ch.isLetter || ch.isNumber
            capitals[j] = (atBow && isAlnum) || ch.isUppercase
            atBow = !isAlnum && ch != "'" && ch != "."
        }

        // Longest-consecutive-match matrix over the allowed (monotonic) band.
        for i in 0..<n {
            var j = i == 0 ? 0 : first[i - 1] + 1
            while j < m {
                if lhs[i].lowercased() == rhs[j].lowercased() {
                    matrix[i][j] = (i == 0 || j == 0) ? 1 : matrix[i - 1][j - 1] + 1
                    first[i] = min(j, first[i])
                    last[i] = max(j + 1, last[i])
                }
                j += 1
            }
        }

        for i in stride(from: n - 1, through: 1, by: -1) {
            var bound = last[i] - 1
            if bound < last[i - 1] {
                while first[i - 1] < bound && matrix[i - 1][bound - 1] == 0 {
                    bound -= 1
                }
                last[i - 1] = bound
            }
        }

        for i in stride(from: n - 1, through: 1, by: -1) {
            for j in first[i]..<last[i] {
                if matrix[i][j] != 0 && matrix[i - 1][j - 1] != 0 {
                    matrix[i - 1][j - 1] = matrix[i][j]
                }
            }
        }

        for i in 0..<n {
            for j in first[i]..<last[i] {
                if matrix[i][j] > 1 && i + 1 < n && j + 1 < m {
                    matrix[i + 1][j + 1] = matrix[i][j] - 1
                }
            }
        }

        // Greedy walk: reconstruct the matched ranges and count statistics.
        var capitalsTouched = 0
        var substrings = 0
        var prefixSize = 0
        var ranges: [Range<Int>] = []

        var i = 0
        while i < n {
            var bestJIndex = 0
            var bestJLength = 0
            for j in first[i]..<last[i] {
                if matrix[i][j] != 0 && capitals[j] {
                    bestJIndex = j
                    bestJLength = matrix[i][j]
                    var k = j
                    while k < j + bestJLength {
                        if capitals[k] { capitalsTouched += 1 }
                        k += 1
                    }
                    break
                } else if bestJLength < matrix[i][j] {
                    bestJIndex = j
                    bestJLength = matrix[i][j]
                }
            }

            if i == 0 {
                prefixSize = bestJIndex
            }

            var len = 0
            var foundCapital = false
            repeat {
                i += 1
                len += 1
                if i == n { break }
                first[i] = max(bestJIndex + len, first[i])
                if len < bestJLength && n < 4 {
                    if capitals[first[i]] { continue }
                    var j = first[i]
                    while j < last[i] && !foundCapital {
                        if matrix[i][j] != 0 && capitals[j] { foundCapital = true }
                        j += 1
                    }
                }
            } while len < bestJLength && !foundCapital

            ranges.append(bestJIndex..<(bestJIndex + len))
            substrings += 1
        }

        let totalCapitals = capitals.reduce(0) { $0 + ($1 ? 1 : 0) }
        let denom = Double(n * (n + 1) + 1)
        var score: Double
        if n == capitalsTouched {
            score = (denom - 1) / denom
        } else {
            let subtract = Double(substrings * n + (n - capitalsTouched))
            score = (denom - subtract) / denom
        }
        score += Double(m - prefixSize) / Double(m) / (2 * denom)
        score += Double(capitalsTouched) / Double(max(totalCapitals, 1)) / (4 * denom)
        score += Double(n) / Double(m) / (8 * denom)

        return RankResult(score: score, ranges: ranges)
    }
}

// MARK: - Indexed file + match

/// A single file discovered during project enumeration, split into the parts
/// the chooser needs for TextMate-style two-part matching.
struct IndexedFile: Sendable {
    let url: URL
    let fileName: String
    let directory: String      // relative parent path, "" for root
    let relativePath: String   // "dir/file.ext", for display/debug
}

/// Which æther a match was drawn from — a project file or a Mnemosyne note.
enum GoToFileSource: Sendable { case file, note }

/// The chooser's search scope — TextMate's open/uncommitted/all, plus the
/// agent's own memory (Mnemosyne) as a first-class ætheric corpus.
enum GoToFileScope: String, CaseIterable, Identifiable, Sendable {
    case open, uncommitted, project, aether

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "Open Documents"
        case .uncommitted: return "Uncommitted"
        case .project: return "All Files"
        case .aether: return "Æther"
        }
    }

    var glyph: String {
        switch self {
        case .open: return "doc.text"
        case .uncommitted: return "arrow.triangle.branch"
        case .project: return "folder"
        case .aether: return "sparkles"
        }
    }
}

/// A scored, highlightable match shown in the list — a file or, in the æther
/// scope, a Mnemosyne note surfaced as a searchable memory.
struct GoToFileMatch: Identifiable, Sendable {
    let url: URL
    let fileName: String
    let directory: String          // raw relative parent ("" for root)
    let rank: Double               // lower = better (0 = unfiltered)
    let fileNameRanges: [Range<Int>]
    let directoryRanges: [Range<Int>]
    var source: GoToFileSource = .file
    var noteText: String? = nil
    var noteID: Int? = nil

    var id: String { source == .file ? url.path : "note-" + String(noteID ?? 0) + "-" + String(fileName.hashValue) }
    var displayDirectory: String { directory.isEmpty ? "." : directory }
}

// MARK: - Matching engine

enum GoToFileEngine {
    /// Directories we never descend into (in addition to hidden dirs, which
    /// `FileManager` skips automatically).
    private static let ignoredDirectories: Set<String> = [
        "node_modules", "Pods", "Carthage", "DerivedData", "__pycache__", "vendor",
    ]

    static func canonicalPath(for url: URL) -> String {
        url.path.withCString { Darwin.realpath($0, nil).map { String(cString: $0) } } ?? url.path
    }

    /// Recursively enumerate the project, skipping hidden/heavy directories
    /// and symlinks. Returns files as `IndexedFile` values.
    static func enumerate(root: URL) -> [IndexedFile] {
        var results: [IndexedFile] = []
        let fm = FileManager.default
        let rootPath = canonicalPath(for: root) + "/"
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            let isSymlink = (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if isSymlink {
                if fileURL.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }

            let rel: String
            if fileURL.path.hasPrefix(rootPath) {
                rel = String(fileURL.path.dropFirst(rootPath.count))
            } else {
                rel = fileURL.lastPathComponent
            }
            guard !rel.isEmpty else { continue }

            let components = rel.components(separatedBy: "/")
            if components.contains(where: { $0.hasPrefix(".") || ignoredDirectories.contains($0) }) {
                if fileURL.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }

            guard !fileURL.hasDirectoryPath else { continue }

            let fileName = components.last ?? rel
            let directory = components.count > 1 ? components.dropLast().joined(separator: "/") : ""
            results.append(IndexedFile(url: fileURL, fileName: fileName, directory: directory, relativePath: rel))
        }
        return results
    }

    /// Port of `FileChooserItem updateRankUsingFilter:` — filename matches
    /// get a +1 bonus, otherwise fall back to matching the full relative path.
    static func match(_ file: IndexedFile, filter: String, currentURL: URL?) -> GoToFileMatch? {
        let isCurrent = currentURL.map { file.url.standardizedFileURL == $0.standardizedFileURL } ?? false
        var rank = isCurrent ? 0.1 : 3.0
        var fileRanges: [Range<Int>] = []
        var dirRanges: [Range<Int>] = []

        if !filter.isEmpty {
            let nameResult = TextMateRanker.rank(filter, file.fileName)
            if nameResult.score > 0 {
                rank = nameResult.score + 1
                fileRanges = nameResult.ranges
            } else {
                let full = file.directory.isEmpty ? file.fileName : file.directory + "/" + file.fileName
                let dirCount = Array(file.directory).count
                let pathResult = TextMateRanker.rank(filter, full)
                if pathResult.score > 0 {
                    rank = pathResult.score
                    for r in pathResult.ranges {
                        if r.lowerBound < dirCount {
                            dirRanges.append(r.lowerBound..<min(r.upperBound, dirCount))
                        }
                        if dirCount + 1 < r.upperBound {
                            let lo = max(r.lowerBound, dirCount + 1) - dirCount - 1
                            let hi = r.upperBound - dirCount - 1
                            if lo < hi { fileRanges.append(lo..<hi) }
                        }
                    }
                } else {
                    rank = 0
                }
            }
        }

        guard rank > 0 else { return nil }
        return GoToFileMatch(
            url: file.url,
            fileName: file.fileName,
            directory: file.directory,
            rank: 3 - rank,
            fileNameRanges: fileRanges,
            directoryRanges: dirRanges
        )
    }

    static func matches(query: String, files: [IndexedFile], currentURL: URL?) -> [GoToFileMatch] {
        let filter = TextMateRanker.normalizeFilter(query)
        if filter.isEmpty {
            return files
                .map { GoToFileMatch(url: $0.url, fileName: $0.fileName, directory: $0.directory, rank: 0, fileNameRanges: [], directoryRanges: []) }
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }

        var results: [GoToFileMatch] = []
        for file in files {
            if let m = match(file, filter: filter, currentURL: currentURL) {
                results.append(m)
            }
        }
        results.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
        return Array(results.prefix(300))
    }
}

// MARK: - Model

@MainActor
final class GoToFileModel: ObservableObject {
    @Published var query: String = ""
    @Published var scope: GoToFileScope = .project
    @Published var results: [GoToFileMatch] = []
    @Published var status: String = "Indexing…"
    @Published var selectedIndex: Int = -1

    private let projectRoot: URL
    private let currentURL: URL?
    private let openPaths: Set<String>
    private var allFiles: [IndexedFile] = []
    private var uncommittedPaths: Set<String> = []
    private var searchTask: Task<Void, Never>?

    init(projectRoot: URL, currentURL: URL?, openPaths: Set<String> = []) {
        self.projectRoot = projectRoot
        self.currentURL = currentURL
        self.openPaths = openPaths
    }

    func start() {
        let root = projectRoot
        loadUncommitted()
        Task.detached(priority: .userInitiated) {
            let files = GoToFileEngine.enumerate(root: root)
            await MainActor.run {
                self.allFiles = files
                self.status = String(files.count) + " files indexed — type to search"
                self.performSearch()
            }
        }
    }

    func selectScope(_ scope: GoToFileScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        selectedIndex = -1
        performSearch()
    }

    func performSearch() {
        searchTask?.cancel()
        let q = query
        let files = allFiles
        let current = currentURL
        let scope = self.scope
        let open = openPaths
        let uncommitted = uncommittedPaths

        searchTask = Task { [weak self] in
            // Debounce. Æther (a remote Mnemosyne query) waits a touch longer
            // so a fast typist never fires a daemon round-trip per keystroke.
            try? await Task.sleep(nanoseconds: scope == .aether ? 140_000_000 : 50_000_000)
            if Task.isCancelled { return }

            let matches: [GoToFileMatch]
            if scope == .aether {
                matches = await self?.fetchAetherMatches(q) ?? []
            } else {
                let scoped = Self.scopedFiles(files, scope: scope, open: open, uncommitted: uncommitted)
                matches = await Task.detached(priority: .userInitiated) {
                    GoToFileEngine.matches(query: q, files: scoped, currentURL: current)
                }.value
            }
            if Task.isCancelled { return }
            self?.results = matches
            self?.selectedIndex = matches.isEmpty ? -1 : 0
            self?.status = Self.statusLine(query: q, matches: matches, scope: scope)
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    func result(at index: Int) -> GoToFileMatch? {
        guard index >= 0, index < results.count else { return nil }
        return results[index]
    }

    // MARK: - Scopes

    private static func scopedFiles(_ files: [IndexedFile], scope: GoToFileScope,
                                    open: Set<String>, uncommitted: Set<String>) -> [IndexedFile] {
        switch scope {
        case .project:
            return files
        case .open:
            return files.filter { open.contains($0.url.standardizedFileURL.path) }
        case .uncommitted:
            return files.filter { uncommitted.contains($0.url.standardizedFileURL.path) }
        case .aether:
            return []
        }
    }

    private func loadUncommitted() {
        let root = projectRoot
        Task.detached(priority: .utility) {
            let paths = Self.gitUncommittedPaths(root: root)
            await MainActor.run { [weak self] in
                self?.uncommittedPaths = paths
                if self?.scope == .uncommitted { self?.performSearch() }
            }
        }
    }

    nonisolated private static func gitUncommittedPaths(root: URL) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "status", "--porcelain=v1", "--untracked-files=all"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let raw = String(data: data, encoding: .utf8) ?? ""
            var paths = Set<String>()
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let p = uncommittedPath(from: String(line), root: root) else { continue }
                paths.insert(p)
            }
            return paths
        } catch {
            return []
        }
    }

    /// Parse one `git status --porcelain=v1` line into a standardized absolute path.
    /// Handles XY status codes, staged/unstaged renames/copies (`R `/`RM`/`MR`/`C ` …),
    /// and C-style quoted paths (`core.quotePath` octal escapes). Returns nil for
    /// malformed lines so stray output (e.g. bare `git diff` "Binary" chatter, though
    /// porcelain v1 emits none) never pollutes the set.
    nonisolated private static func uncommittedPath(from line: String, root: URL) -> String? {
        guard line.count >= 4 else { return nil }
        let statusX = line[line.startIndex]
        let statusY = line[line.index(after: line.startIndex)]
        var path = String(line.dropFirst(3))

        // Rename/copy: `R  old -> new`, `RM old -> new`, `MR old -> new`, `C  old -> new`.
        // The right side is the live destination path.
        if statusX == "R" || statusY == "R" || statusX == "C" || statusY == "C" {
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
        }

        path = gitUnquote(path).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        guard !url.path.isEmpty, url.path != root.standardizedFileURL.path else { return nil }
        return url.path
    }

    /// Decode git's C-style path quoting (`core.quotePath`): `\"`, `\\`, `\n`, `\t`,
    /// and octal byte escapes (`\342\200\246`) for non-ASCII / control bytes. Accumulates
    /// raw UTF-8 bytes so multi-byte escapes recombine into the correct scalars.
    nonisolated private static func gitUnquote(_ s: String) -> String {
        guard s.contains("\"") || s.contains("\\") else { return s }
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" {
                i = s.index(after: i)
                continue
            }
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { break }
                switch s[next] {
                case "n": bytes.append(0x0A); i = s.index(after: next)
                case "t": bytes.append(0x09); i = s.index(after: next)
                case "r": bytes.append(0x0D); i = s.index(after: next)
                case "\"": bytes.append(0x22); i = s.index(after: next)
                case "\\": bytes.append(0x5C); i = s.index(after: next)
                case "0"..."7":
                    var v = 0
                    var j = next
                    var count = 0
                    while count < 3, j < s.endIndex, let d = s[j].wholeNumberValue, (0...7).contains(d) {
                        v = v * 8 + d
                        j = s.index(after: j)
                        count += 1
                    }
                    bytes.append(UInt8(v & 0xFF))
                    i = j
                default:
                    if let ascii = s[next].asciiValue { bytes.append(ascii) }
                    i = s.index(after: next)
                }
            } else {
                for b in String(c).utf8 { bytes.append(b) }
                i = s.index(after: i)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }

    private func fetchAetherMatches(_ query: String) async -> [GoToFileMatch] {
        do {
            if !RubyBridge.shared.isRunning { try? await RubyBridge.shared.start() }
            let notes = try await RubyBridge.shared.recallNotes(query: query, limit: 50)
            return notes.compactMap { Self.noteMatch(from: $0) }
        } catch {
            return []
        }
    }

    private static func noteMatch(from dict: [String: Any]) -> GoToFileMatch? {
        let id = (dict["id"] as? Int) ?? (dict["id"] as? String).flatMap(Int.init)
        guard let content = dict["content"] as? String, !content.isEmpty else { return nil }
        let tags = (dict["tags"] as? String)?
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let title = "#" + (id.map { String($0) } ?? "?")
        let directory = tags.isEmpty ? "Mnemosyne" : tags.joined(separator: " · ")
        let placeholder = URL(string: "aether://note/" + String(id ?? 0)) ?? URL(fileURLWithPath: "/")
        return GoToFileMatch(url: placeholder, fileName: title, directory: directory,
                             rank: 0, fileNameRanges: [], directoryRanges: [],
                             source: .note, noteText: content, noteID: id)
    }

    private static func statusLine(query: String, matches: [GoToFileMatch], scope: GoToFileScope) -> String {
        if matches.isEmpty {
            return query.isEmpty ? "No matches" : "No matches for “" + query + "”"
        }
        let noun = matches.count == 1 ? "match" : "matches"
        return String(matches.count) + " " + noun + " in " + scope.label
    }
}

// MARK: - SwiftUI view

struct GoToFileView: View {
    @ObservedObject var model: GoToFileModel
    let onSelect: (URL) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultList
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            model.start()
            // The panel becomes key only after it is on screen — focus the
            // field one runloop later so it always accepts keystrokes.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.query) { _, _ in
            model.performSearch()
        }
        .onChange(of: model.scope) { _, _ in
            model.performSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(scopePlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { accept() }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(+1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
            scopePicker
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var scopePlaceholder: String {
        model.scope == .aether ? "Search the æther…" : "Go to File"
    }

    private var scopePicker: some View {
        Menu {
            ForEach(GoToFileScope.allCases) { scope in
                Button {
                    model.selectScope(scope)
                } label: {
                    if scope == model.scope {
                        Label(scope.label, systemImage: "checkmark")
                    } else {
                        Label(scope.label, systemImage: scope.glyph)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.scope.glyph)
                    .font(.system(size: 11, weight: .semibold))
                Text(model.scope.label)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var resultList: some View {
        if model.results.isEmpty {
            Spacer()
            Text(model.status)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, match in
                            row(match, isSelected: index == model.selectedIndex)
                                .id(match.id)
                                .onTapGesture { model.selectedIndex = index }
                                .onTapGesture(count: 2) { accept(index) }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selectedIndex) { _, newIndex in
                    guard newIndex >= 0, newIndex < model.results.count else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(model.results[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text(model.status)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func row(_ match: GoToFileMatch, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            leadingIcon(match)
            VStack(alignment: .leading, spacing: 1) {
                if match.source == .note {
                    Text(match.noteText ?? "")
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? .white : Color.primary)
                    Text(match.displayDirectory)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                } else {
                    highlighted(match.fileName, ranges: match.fileNameRanges, size: 13)
                        .foregroundStyle(isSelected ? .white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    highlighted(match.displayDirectory, ranges: match.directoryRanges, size: 10)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
    }

    @ViewBuilder
    private func leadingIcon(_ match: GoToFileMatch) -> some View {
        if match.source == .note {
            Text("🪷")
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: match.url.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }

    /// Build a `Text` with the matched ranges emphasized (bold), mirroring
    /// TextMate's marked-up ranges.
    private func highlighted(_ string: String, ranges: [Range<Int>], size: CGFloat) -> Text {
        let chars = Array(string)
        var attributed = AttributedString(string)
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        for r in sorted {
            let lo = max(0, r.lowerBound)
            let hi = min(chars.count, r.upperBound)
            guard lo < hi else { continue }
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: lo)
            let upper = attributed.index(attributed.startIndex, offsetByCharacters: hi)
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed).font(.system(size: size))
    }

    private func accept(_ index: Int? = nil) {
        let i = index ?? model.selectedIndex
        guard let match = model.result(at: i) else { return }
        if match.source == .note, let text = match.noteText {
            // Selecting a memory copies its content — the chooser opens files;
            // the æther hands its knowledge back to the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onDismiss()
            return
        }
        onSelect(match.url)
    }
}

// MARK: - Scene content

/// The Go to File palette as a scene.
///
/// The `NSWindowController` this replaced owned the result callback privately
/// and used `objc_setAssociatedObject` to keep itself alive while its borderless
/// panel was up. The callback now travels in the `GoToFileRequest`, and the
/// palette's lifetime is the scene's.
@MainActor
struct GoToFileScene: View {
    @ObservedObject private var scene = AppScene.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let request = scene.goToFile {
                // A fresh invocation is a fresh palette: new model, new root,
                // new focus. Without this the previous search would survive
                // into the next ⌘T.
                GoToFilePalette(request: request).id(request.id)
            } else {
                Color.clear
            }
        }
        // A palette lives only while the app is in front — the old panel's
        // `hidesOnDeactivate`. No scene modifier expresses that, so the
        // resignation is observed directly.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            dismissWindow(id: AppWindowID.goToFile)
        }
    }
}

@MainActor
private struct GoToFilePalette: View {
    let request: GoToFileRequest
    @StateObject private var model: GoToFileModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(request: GoToFileRequest) {
        self.request = request
        _model = StateObject(wrappedValue: GoToFileModel(
            projectRoot: request.projectRoot,
            currentURL: request.currentURL,
            openPaths: request.openPaths
        ))
    }

    var body: some View {
        GoToFileView(
            model: model,
            onSelect: { url in
                request.onSelect(url)
                dismissWindow(id: AppWindowID.goToFile)
            },
            onDismiss: { dismissWindow(id: AppWindowID.goToFile) }
        )
        // The palette's chrome used to be a hand-built layer stack: a rounded,
        // bordered container over an `NSVisualEffectView`. The scene is
        // `.plain`, so the silhouette is the view's to draw.
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
    }
}