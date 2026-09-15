import SwiftUI

private struct MarkdownThemeNameKey: EnvironmentKey {
    static let defaultValue = ""
}
extension EnvironmentValues {
    var markdownThemeName: String {
        get { self[MarkdownThemeNameKey.self] }
        set { self[MarkdownThemeNameKey.self] = newValue }
    }
}

// MARK: - Block model

/// Lightweight markdown block parser: separates fenced code blocks from prose
/// and detects headings/lists so Pythia bubbles render with a proper
/// typographic hierarchy instead of one flat run of text.
struct MarkdownBlock: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case code(String, String)
        case table([String], [[String]])
        case quote(String)
        case rule
        case heading(String, Int)
        case list([ListItem])
        case paragraph(String)
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var listBuffer: [ListItem] = []
        var i = 0

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph(paragraphBuffer.joined(separator: " "))))
            paragraphBuffer.removeAll()
        }
        func flushList() {
            guard !listBuffer.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .list(listBuffer)))
            listBuffer.removeAll()
        }

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // Fenced code block (``` or ~~~).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                flushParagraph(); flushList()
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1  // closing fence
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .code(codeLines.joined(separator: "\n"), language)))
                continue
            }

            if i + 1 < lines.count, trimmed.contains("|"), isTableDivider(lines[i + 1]) {
                flushParagraph(); flushList()
                let header = cells(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(MarkdownBlock(kind: .table(header, rows)))
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                flushParagraph(); flushList()
                blocks.append(MarkdownBlock(kind: .rule)); i += 1; continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph(); flushList()
                blocks.append(MarkdownBlock(kind: .quote(String(trimmed.dropFirst(2)))))
                i += 1; continue
            }

            if let (level, content) = parseHeading(trimmed) {
                flushParagraph(); flushList()
                blocks.append(MarkdownBlock(kind: .heading(content, level)))
                i += 1
                continue
            }

            if let content = parseUnordered(trimmed) {
                flushParagraph()
                listBuffer.append(ListItem(text: content, ordered: false, index: listBuffer.count + 1))
                i += 1
                continue
            }

            if let (index, content) = parseOrdered(trimmed) {
                flushParagraph()
                listBuffer.append(ListItem(text: content, ordered: true, index: index))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(); flushList()
                i += 1
                continue
            }

            if !listBuffer.isEmpty { flushList() }
            paragraphBuffer.append(trimmed)
            i += 1
        }
        flushParagraph()
        flushList()
        return blocks
    }

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = [], cell = ""
        var escaped = false, code = false
        for character in text {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result
    }

    static func isTableDivider(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }

    private static func parseHeading(_ s: String) -> (Int, String)? {
        var level = 0
        for c in s {
            if c == "#" { level += 1 } else { break }
        }
        guard level > 0, level <= 6 else { return nil }
        let start = s.index(s.startIndex, offsetBy: level)
        if start < s.endIndex, s[start] != " " { return nil }
        let content = String(s[start...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (level, content)
    }

    private static func parseUnordered(_ s: String) -> String? {
        for marker in ["- ", "* ", "• "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseOrdered(_ s: String) -> (Int, String)? {
        var digits = ""
        for c in s {
            if c.isNumber { digits.append(c) } else { break }
        }
        guard !digits.isEmpty else { return nil }
        let afterDigits = s.index(s.startIndex, offsetBy: digits.count)
        guard afterDigits < s.endIndex, s[afterDigits] == "." else { return nil }
        let afterDot = s.index(after: afterDigits)
        guard afterDot < s.endIndex, s[afterDot] == " " else { return nil }
        let content = String(s[afterDot...]).trimmingCharacters(in: .whitespaces)
        return (Int(digits) ?? 1, content)
    }
}

struct ListItem: Identifiable {
    let id = UUID()
    let text: String
    let ordered: Bool
    let index: Int
}

// MARK: - Inline rendering

/// Render inline content as an AttributedString. `AttributedString(markdown:)`
/// does not interpret raw HTML, so common tags are first normalized to their
/// Markdown equivalents and unknown tags are stripped — the model occasionally
/// wraps its answers in `<div>`/`<b>`/`<em>` etc.
func renderInline(_ text: String) -> AttributedString {
    let cleaned = htmlToMarkdown(text)
    let base = (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cleaned)
    return themeInlineRuns(base)
}

/// Recolor inline runs (code, bold, italic, strikethrough) from the theme's
/// markup scopes — mirroring how TextMate's markdown preview inherits the
/// editor theme — so emphasis reads as a document, not platform-default gray.
private func themeInlineRuns(_ string: AttributedString) -> AttributedString {
    var out = string
    let theme = ThemeRegistry.shared.current
    for run in out.runs {
        let intents = run.inlinePresentationIntent ?? []
        if intents.contains(.code) {
            let scope = theme.style(for: .inlineCode)
            let fg = scope.foreground ?? theme.pythia.codeForeground
            let bg = scope.background ?? theme.pythia.codeBackground
            out[run.range].foregroundColor = Color(nsColor: fg)
            out[run.range].backgroundColor = Color(nsColor: scope.background == nil ? bg.withAlphaComponent(0.55) : bg)
        } else if intents.contains(.stronglyEmphasized), let fg = theme.style(for: .strong).foreground {
            out[run.range].foregroundColor = Color(nsColor: fg)
        } else if intents.contains(.emphasized), let fg = theme.style(for: .emphasis).foreground {
            out[run.range].foregroundColor = Color(nsColor: fg)
        } else if intents.contains(.strikethrough), let fg = theme.style(for: .strikethrough).foreground {
            out[run.range].foregroundColor = Color(nsColor: fg)
        }
    }
    return out
}

/// Best-effort HTML→Markdown normalization for the tags the oracle actually
/// emits. Unknown tags are dropped (their text content is preserved).
private func htmlToMarkdown(_ s: String) -> String {
    var t = s
    t = t.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<strong>", with: "**", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "</strong>", with: "**", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<b>", with: "**", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "</b>", with: "**", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<em>", with: "_", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "</em>", with: "_", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<i>", with: "_", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "</i>", with: "_", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "<code>", with: "`", options: .caseInsensitive)
    t = t.replacingOccurrences(of: "</code>", with: "`", options: .caseInsensitive)
    t = fileLinkify(t)
    t = linkify(t)
    t = t.replacingOccurrences(of: #"</?(?:p|div|span|section|article|strong|em|b|i|code|a)(?:\s[^>]*)?>"#, with: "", options: [.regularExpression, .caseInsensitive])
    for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
        t = t.replacingOccurrences(of: entity, with: value)
    }
    return t
}

/// `<a href="X">Y</a>` → `[Y](X)` so links stay tappable.
private func linkify(_ s: String) -> String {
    let pattern = #"<a\s+[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
    let ns = s as NSString
    var t = s
    for m in regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).reversed() {
        guard m.numberOfRanges >= 3 else { continue }
        let href = ns.substring(with: m.range(at: 1))
        let label = ns.substring(with: m.range(at: 2))
        t = (t as NSString).replacingCharacters(in: m.range, with: "[\(label)](\(href))")
    }
    return t
}

/// `<file path="A/B.swift" line="1" column="2">name</file>` and `<file>A/B.swift</file>`
/// → `[name](aethercodex://open?path=...)` so file references stay tappable.
private func fileLinkify(_ s: String) -> String {
    let pattern = #"<file\b([^>]*)>(.*?)</file>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
    let ns = s as NSString
    var t = s
    for m in regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).reversed() {
        guard m.numberOfRanges >= 3 else { continue }
        let attrs = ns.substring(with: m.range(at: 1))
        let inner = ns.substring(with: m.range(at: 2))
        let path = attributeValue("path", in: attrs) ?? inner
        guard !path.isEmpty else { continue }
        let label = inner.isEmpty ? path : inner
        var comps = URLComponents()
        comps.scheme = "aethercodex"
        comps.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let line = attributeValue("line", in: attrs) { items.append(URLQueryItem(name: "line", value: line)) }
        if let column = attributeValue("column", in: attrs) { items.append(URLQueryItem(name: "column", value: column)) }
        comps.queryItems = items
        let link = comps.url?.absoluteString ?? ""
        t = (t as NSString).replacingCharacters(in: m.range, with: "[\(label)](\(link))")
    }
    return t
}

private func attributeValue(_ name: String, in attrs: String) -> String? {
    let pattern = "\\b\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let ns = attrs as NSString
    guard let m = regex.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges >= 2 else { return nil }
    return ns.substring(with: m.range(at: 1))
}

/// Resolves an `aethercodex://open` URL from an inline file link and routes it
/// through the same resolver the memory cauldron uses.
private enum FileLinkResolver {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "aethercodex", url.host == "open",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = comps.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else { return false }
        MnemosyneLinkResolver.open(path)
        return true
    }
}

// MARK: - Markdown body

struct MarkdownBody: View {
    let text: String
    var plain = false
    @Environment(\.markdownThemeName) private var themeName
    @State private var settingsRevision = 0

    var body: some View {
        let _ = themeName
        let _ = settingsRevision
        Group {
        if plain || text.isEmpty {
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(MarkdownBlock.parse(text)) { block in
                    blockView(block)
                }
            }
        }
        }
        .foregroundStyle(Color(nsColor: ThemeRegistry.shared.current.sidebarForeground))
        .tint(Color(nsColor: ThemeRegistry.shared.current.style(for: .link).foreground ?? ThemeRegistry.shared.current.sidebarAccent))
        .environment(\.openURL, OpenURLAction { url in
            FileLinkResolver.handle(url) ? .handled : .systemAction
        })
        .onReceive(NotificationCenter.default.publisher(for: ThemeSettings.didChangeNotification)) { _ in settingsRevision += 1 }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .code(let code, let language):
            CodeBlockView(code: code, language: language)
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        case .quote(let text):
            BlockquoteView(text: text)
        case .rule:
            Rectangle()
                .fill(Color(nsColor: ThemeRegistry.shared.current.style(for: .thematicBreak).foreground ?? ThemeRegistry.shared.current.pythia.shine).opacity(0.4))
                .frame(height: 1)
                .padding(.vertical, 6)
        case .heading(let text, let level):
            HeadingView(text: text, level: level)
        case .list(let items):
            ListView(items: items)
        case .paragraph(let text):
            Text(renderInline(text))
                .font(Font(ThemeSettings.shared.resolvedProportionalFont))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Block views

/// Tokenize `code` with the theme's syntax scopes and return a theme-colored
/// AttributedString. Falls back to the editor foreground when the language is
/// unknown. Shared by fenced code blocks and the Pythia CLI shell blocks so both
/// hands speak the same theme syntax.
func highlightCode(_ code: String, language: String, fallback: NSColor? = nil) -> AttributedString {
    let theme = ThemeRegistry.shared.current
    let result = NSMutableAttributedString(string: code, attributes: [.foregroundColor: fallback ?? theme.pythia.codeForeground])
    let engine = TreeSitterEngine()
    let aliases = ["javascript": "js", "typescript": "ts", "python": "py", "ruby": "rb",
                   "shell": "sh", "bash": "sh", "zsh": "sh", "swift": "swift"]
    if engine.setLanguage(forExtension: aliases[language.lowercased()] ?? language.lowercased()) {
        let range = NSRange(location: 0, length: result.length)
        for token in engine.tokenize(code, in: range) where NSMaxRange(token.range) <= result.length {
            if let color = theme.style(for: token.scope).foreground {
                result.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }
    }
    return AttributedString(result)
}

private struct CodeBlockView: View {
    let code: String
    let language: String

    var body: some View {
        let theme = ThemeRegistry.shared.current
        let scope = theme.style(for: .codeBlock)
        LineNumberedCodeView(code: code,
                             language: language,
                             font: .system(size: 11.5, design: .monospaced),
                             fontSize: 11.5,
                             lineSpacing: 2,
                             background: Color(nsColor: scope.background ?? theme.pythia.codeBackground),
                             border: Color(nsColor: theme.pythia.shine).opacity(0.14),
                             fallback: scope.foreground ?? theme.pythia.codeForeground)
    }
}

private struct HeadingView: View {
    let text: String
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(renderInline(text))
                .font(Font(MarkdownRichCodec.font(level: level)))
                .foregroundStyle(Color(nsColor: ThemeRegistry.shared.current.style(for: TokenScope(rawValue: "markup.heading.\(level)") ?? .heading).foreground ?? ThemeRegistry.shared.current.sidebarAccent))
                .lineSpacing(3)
                .textSelection(.enabled)
            if level <= 2 {
                Rectangle()
                    .fill(Color(nsColor: ThemeRegistry.shared.current.style(for: .thematicBreak).foreground ?? ThemeRegistry.shared.current.pythia.shine).opacity(level == 1 ? 0.35 : 0.18))
                    .frame(height: 1)
            }
        }
        .padding(.top, level <= 2 ? 2 : 0)
    }
}

private struct BlockquoteView: View {
    let text: String

    var body: some View {
        let theme = ThemeRegistry.shared.current
        let scope = theme.style(for: .blockquote)
        let bar = scope.foreground ?? theme.pythia.complementary
        let wash = scope.background ?? bar.withAlphaComponent(0.08)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Color(nsColor: bar)).frame(width: 3)
            Text(renderInline(text))
                .italic()
                .foregroundStyle(Color(nsColor: scope.foreground ?? theme.pythia.foreground))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: wash))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 3)
    }
}

private struct ListView: View {
    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(for: item))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: markerColor(for: item)))
                        .frame(width: 16, alignment: .trailing)
                    Text(renderInline(label(for: item)))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func marker(for item: ListItem) -> String {
        if item.text.hasPrefix("[x] ") || item.text.hasPrefix("[X] ") { return "☑" }
        if item.text.hasPrefix("[ ] ") { return "☐" }
        return item.ordered ? "\(item.index)." : "•"
    }

    private func label(for item: ListItem) -> String {
        if item.text.hasPrefix("[ ] ") || item.text.lowercased().hasPrefix("[x] ") {
            return String(item.text.dropFirst(4))
        }
        return item.text
    }

    private func markerColor(for item: ListItem) -> NSColor {
        let theme = ThemeRegistry.shared.current
        if item.text.hasPrefix("[x] ") || item.text.hasPrefix("[X] ") {
            return theme.style(for: .checkedListItem).foreground ?? theme.pythia.complementary
        }
        return .secondaryLabelColor
    }
}