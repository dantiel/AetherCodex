import Foundation

// MARK: - Per-file result group

/// One file's search results — a group with its hit count. Streamed off the
/// main actor, then applied to the model in batches so a huge tree never
/// freezes the editor while the result list fills.
struct ProjectFileMatch: Identifiable, Sendable {
    let url: URL
    let matches: [ProjectMatch]
    var id: URL { url }
    var count: Int { matches.count }
}

enum ProjectSearchError: LocalizedError {
    case invalidRegularExpression(String)

    var errorDescription: String? {
        switch self {
        case .invalidRegularExpression(let pattern):
            return "Invalid regular expression: \(pattern)"
        }
    }
}

// MARK: - Engine

/// Walks `roots`, matches text content and reports per-file groups to `onBatch`
/// (called off the main actor). Cooperative cancellation via `Task.isCancelled`.
/// Honors .gitignore-style exclusions, skips binaries by content sniff, guards
/// against symlink loops and caps file/match counts — the same discipline as
/// the old `grepProject`, now streaming and error-surfacing.
func runProjectSearch(
    roots: [URL],
    query: String,
    ignoreCase: Bool,
    wholeWord: Bool,
    regularExpression: Bool,
    onBatch: @Sendable ([ProjectFileMatch]) async -> Void
) async throws {
    let regex: NSRegularExpression?
    if regularExpression {
        guard let r = try? NSRegularExpression(
            pattern: query,
            options: ignoreCase ? [.caseInsensitive] : []
        ) else {
            throw ProjectSearchError.invalidRegularExpression(query)
        }
        regex = r
    } else {
        regex = nil
    }

    let maxFiles = 500
    let maxMatches = 2000
    let batchMatchCount = 50
    var filesSeen = 0
    var totalMatches = 0
    var batch: [ProjectFileMatch] = []
    var batchCount = 0

    func flush() async {
        guard !batch.isEmpty else { return }
        await onBatch(batch)
        batch.removeAll(keepingCapacity: true)
        batchCount = 0
    }

    for root in roots {
        let gitignore = GitIgnoreMatcher(root: root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { continue }

        var visited = Set<String>()

        outer: for case let url as URL in enumerator {
            if Task.isCancelled || totalMatches >= maxMatches || filesSeen >= maxFiles {
                break outer
            }
            if isSkippedProjectPath(url.path) { continue }

            // Symlink-loop guard: resolve once and dedupe by canonical path.
            let resolved = url.resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { continue }

            let relative = relativePath(of: url, from: root)
            if gitignore.isIgnored(relative) { continue }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }

            guard let data = try? Data(contentsOf: url) else { continue }
            guard isTextData(data) else { continue }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { continue }

            let matches = scanFile(
                text: text,
                url: url,
                query: query,
                ignoreCase: ignoreCase,
                wholeWord: wholeWord,
                regex: regex
            )
            guard !matches.isEmpty else { continue }

            filesSeen += 1
            totalMatches += matches.count
            let capped = Array(matches.prefix(100))
            batch.append(ProjectFileMatch(url: url, matches: capped))
            batchCount += capped.count
            if batchCount >= batchMatchCount {
                await flush()
            }
        }
    }
    await flush()
}

// MARK: - Per-file scanning

private func scanFile(
    text: String,
    url: URL,
    query: String,
    ignoreCase: Bool,
    wholeWord: Bool,
    regex: NSRegularExpression?
) -> [ProjectMatch] {
    let ns = text as NSString
    var ranges: [NSRange] = []

    if let regex {
        ranges = regex
            .matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            .map(\.range)
    } else {
        var opts: NSString.CompareOptions = [.literal]
        if ignoreCase { opts.insert(.caseInsensitive) }
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let r = ns.range(of: query, options: opts, range: searchRange)
            guard r.location != NSNotFound else { break }
            if wholeWord && !isWholeWord(ns, range: r) {
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

    return ranges.map { r in
        ProjectMatch(
            url: url,
            line: lineNumber(at: r.location, in: ns),
            column: columnNumber(at: r.location, in: ns),
            range: r,
            lineText: lineText(at: r.location, in: ns)
        )
    }
}

// MARK: - Skip / sniff / path helpers

private func isSkippedProjectPath(_ path: String) -> Bool {
    let skip = Set([".git", "node_modules", "Pods", "Carthage", "build", "DerivedData",
                    ".build", "vendor", ".svn", ".hg", "xcuserdata", ".idea"])
    return path.split(separator: "/").map(String.init).contains { skip.contains($0) }
}

private func isTextData(_ data: Data) -> Bool {
    !data.prefix(8192).contains(0)
}

private func relativePath(of url: URL, from root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let urlPath = url.standardizedFileURL.path
    guard urlPath.hasPrefix(rootPath) else { return urlPath }
    return String(urlPath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
}

// MARK: - Line/column geometry

private func lineNumber(at index: Int, in ns: NSString) -> Int {
    let end = min(max(index, 0), ns.length)
    var line = 1
    var i = 0
    while i < end {
        if ns.character(at: i) == 0x0A { line += 1 }
        i += 1
    }
    return line
}

private func columnNumber(at index: Int, in ns: NSString) -> Int {
    var start = 0
    var end = 0
    ns.getLineStart(&start, end: &end, contentsEnd: nil, for: NSRange(location: index, length: 0))
    return index - start + 1 // 1-based UTF-16 column
}

private func lineText(at index: Int, in ns: NSString) -> String {
    var start = 0
    var end = 0
    ns.getLineStart(&start, end: &end, contentsEnd: nil, for: NSRange(location: index, length: 0))
    return ns.substring(with: NSRange(location: start, length: end - start))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isWholeWord(_ s: NSString, range: NSRange) -> Bool {
    func word(_ i: Int) -> Bool {
        guard i >= 0, i < s.length else { return false }
        let c = s.character(at: i)
        if c == 0x5F { return true }
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
    return !word(range.location - 1) && !word(NSMaxRange(range))
}

// MARK: - .gitignore matcher (lightweight)

/// Parses the root `.gitignore` and applies a pragmatic subset: blank/`#`
/// lines are skipped, `!` negates, a trailing `/` marks directory-only, a
/// leading `/` anchors to the root, `*`/`?` are globs, `**` crosses slashes.
struct GitIgnoreMatcher {
    private struct Rule {
        let pattern: String
        let negated: Bool
        let dirOnly: Bool
    }

    private let rules: [Rule]

    init(root: URL) {
        let url = root.appendingPathComponent(".gitignore")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            rules = []
            return
        }
        rules = content.split(separator: "\n").compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            var negated = false
            if s.hasPrefix("!") {
                negated = true
                s.removeFirst()
            }
            let dirOnly = s.hasSuffix("/")
            if dirOnly { s.removeLast() }
            guard !s.isEmpty else { return nil }
            return Rule(pattern: s, negated: negated, dirOnly: dirOnly)
        }
    }

    func isIgnored(_ relPath: String) -> Bool {
        let path = relPath.hasPrefix("/") ? String(relPath.dropFirst()) : relPath
        var ignored = false
        for rule in rules {
            if matches(rule, path: path) {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    private func matches(_ rule: Rule, path: String) -> Bool {
        let anchored = rule.pattern.hasPrefix("/")
        let p = anchored ? String(rule.pattern.dropFirst()) : rule.pattern

        var regexPattern = ""
        var i = p.startIndex
        while i < p.endIndex {
            let c = p[i]
            let next = p.index(after: i)
            if c == "*" {
                if next < p.endIndex && p[next] == "*" {
                    regexPattern += ".*"
                    i = p.index(after: next)
                    continue
                }
                regexPattern += "[^/]*"
                i = next
                continue
            } else if c == "?" {
                regexPattern += "[^/]"
                i = next
                continue
            } else {
                regexPattern += NSRegularExpression.escapedPattern(for: String(c))
                i = next
            }
        }

        var full = regexPattern
        if rule.dirOnly { full += "(/.*)?" }
        if !anchored { full = "(^|.*/)" + full }
        full = "^" + full + "$"

        guard let regex = try? NSRegularExpression(pattern: full) else { return false }
        let range = NSRange(location: 0, length: (path as NSString).length)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }
}
