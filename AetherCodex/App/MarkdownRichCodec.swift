import AppKit

/// Conservative-but-complete Markdown editing vocabulary for the WYSIWYG
/// rich-text surface. Structural syntax — headings, lists, quotes, code fences —
/// is *hidden* from the visible text and reconstructed on save, so the editor
/// reads as a real rich-text editor while round-tripping Markdown byte-exact.
/// Unsupported syntax stays literal; pristine paragraphs retain their exact source.
enum MarkdownRichCodec {
    static let prefix = NSAttributedString.Key("aether.markdown.prefix")
    static let inlineCode = NSAttributedString.Key("aether.markdown.code")
    static let originalLine = NSAttributedString.Key("aether.markdown.original")
    static let renderedLine = NSAttributedString.Key("aether.markdown.rendered")
    static let literalLine = NSAttributedString.Key("aether.markdown.literal")
    static let imageSource = NSAttributedString.Key("aether.markdown.image")
    static let tableDivider = NSAttributedString.Key("aether.markdown.tableDivider")
    static let codeFence = NSAttributedString.Key("aether.markdown.codeFence")
    static let originalBlock = NSAttributedString.Key("aether.markdown.blockOriginal")
    static let renderedBlock = NSAttributedString.Key("aether.markdown.blockRendered")

    enum ListKind { case bullet, ordered, task }

    /// Renders a todo marker as a fixed column glyph instead of AppKit's small
    /// native checkbox/checkmark: `◯` (open) vs `✔` (done). Subclassing
    /// `NSTextList` lets us override the marker string per item while keeping the
    /// native list layout (indent, hanging marker, paragraph flow).
    final class TaskMarkerList: NSTextList {
        let checked: Bool
        init(checked: Bool) {
            self.checked = checked
            // Call the *designated* initializer directly. `NSTextList`'s
            // `init(markerFormat:options:)` is a convenience initializer that
            // redispatches to `init(markerFormat:options:startingItemNumber:)`
            // on `self` — which a Swift subclass does not implement, aborting
            // with "Use of unimplemented initializer".
            super.init(markerFormat: .box, options: [], startingItemNumber: 1)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func marker(forItemNumber itemNum: Int) -> String {
            checked ? "✔" : "◯"
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 2
        return [.font: font(level: 0), .foregroundColor: ThemeRegistry.shared.current.editorForeground,
                .paragraphStyle: paragraph]
    }

    static func font(level: Int) -> NSFont {
        let base = ThemeSettings.shared.resolvedProportionalFont
        guard level > 0 else { return base }
        let style = ThemeRegistry.shared.current.style(for: TokenScope(rawValue: "markup.heading.\(level)") ?? .heading)
        let requested = style.fontSize ?? [1: 1.8, 2: 1.5, 3: 1.25][level, default: 1.1]
        let size = requested <= 4 ? base.pointSize * requested : requested
        let chosen = style.fontName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFontManager.shared.convert(base, toSize: size)
        return NSFontManager.shared.convert(chosen, toHaveTrait: .boldFontMask)
    }

    // MARK: - Rendering

    static func render(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = source.components(separatedBy: "\n")
        let newline = NSAttributedString(string: "\n", attributes: baseAttributes)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let image = localImage(line) {
                result.append(image)
                if i < lines.count - 1 { result.append(newline) }
                i += 1
                continue
            }
            if i + 1 < lines.count, line.contains("|"), MarkdownBlock.isTableDivider(lines[i + 1]) {
                var rows = [MarkdownBlock.cells(line)]
                var next = i + 2
                while next < lines.count, lines[next].contains("|"), !lines[next].isEmpty {
                    rows.append(MarkdownBlock.cells(lines[next])); next += 1
                }
                let table = NSMutableAttributedString(attributedString: RichTextTable.make(rows))
                table.addAttribute(tableDivider, value: lines[i + 1], range: NSRange(location: 0, length: table.length))
                result.append(table)
                i = next
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var j = i + 1
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { j += 1 }
                let hasClose = j < lines.count
                let closeIndex = hasClose ? j : lines.count - 1
                result.append(renderFencedBlock(lines: lines, from: i, fence: fence, language: language, closeIndex: closeIndex, hasClose: hasClose))
                if closeIndex < lines.count - 1 { result.append(newline) }
                i = j + 1
                continue
            }
            if !isLiteral(line) {
                if trimmed.hasPrefix("> ") {
                    result.append(renderQuoteGroup(lines: lines, from: &i))
                    continue
                }
                if parseList(trimmed) != nil {
                    result.append(renderListGroup(lines: lines, from: &i))
                    continue
                }
            }
            result.append(renderLine(line, last: i == lines.count - 1))
            i += 1
        }
        return result
    }

    /// Lines that must never be interpreted as structure — escaped syntax,
    /// images, raw HTML, indented code, reference definitions.
    private static func isLiteral(_ line: String) -> Bool {
        line.contains("\\") || line.contains("![") || line.contains("<") || line.contains("|")
            || line.contains("][") || line.range(of: #"^\s*\[[^]]+\]:"#, options: .regularExpression) != nil
            || line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func parseList(_ s: String) -> (kind: ListKind, marker: String, content: String)? {
        if let m = s.range(of: #"^([-*+])\s+\[([ xX])\]\s+"#, options: .regularExpression) {
            return (.task, String(s[m]), String(s[m.upperBound...]))
        }
        if let m = s.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            return (.bullet, String(s[m]), String(s[m.upperBound...]))
        }
        if let m = s.range(of: #"^[0-9]+\.\s+"#, options: .regularExpression) {
            return (.ordered, String(s[m]), String(s[m.upperBound...]))
        }
        return nil
    }

    /// One non-structural line: heading, literal line, or plain paragraph.
    private static func renderLine(_ line: String, last: Bool) -> NSAttributedString {
        var body = line
        var marker = ""
        var level = 0
        let literal = isLiteral(line)
        if !literal, let match = line.range(of: #"^(#{1,6} )"#, options: .regularExpression) {
            marker = String(line[match])
            body = String(line[match.upperBound...])
            level = marker.prefix(while: { $0 == "#" }).count
        }
        let text = NSMutableAttributedString(string: body, attributes: baseAttributes)
        let full = NSRange(location: 0, length: text.length)
        if literal {
            text.addAttribute(.font, value: ThemeSettings.shared.resolvedMonoFont, range: full)
            text.addAttribute(literalLine, value: true, range: full)
        } else {
            text.addAttribute(.font, value: font(level: level), range: full)
            if level > 0 {
                let scope = TokenScope(rawValue: "markup.heading.\(level)") ?? .heading
                text.addAttribute(.foregroundColor, value: ThemeRegistry.shared.current.style(for: scope).foreground
                                  ?? ThemeRegistry.shared.current.sidebarAccent, range: full)
                // Real native heading block — `headerLevel` makes the document a
                // structured rich-text outline, not just a larger font.
                let heading = NSMutableParagraphStyle()
                heading.headerLevel = level
                heading.lineSpacing = 2
                heading.paragraphSpacing = 4
                text.addAttribute(.paragraphStyle, value: heading, range: full)
            }
            inline(text, pattern: #"`([^`\n]+)`"#, kind: "code")
            inline(text, pattern: #"\[([^\]\n]+)\]\(([^\s)]+)\)"#, kind: "link")
            inline(text, pattern: #"\*\*([^*\n]+)\*\*"#, kind: "bold")
            inline(text, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, kind: "italic")
            inline(text, pattern: #"~~([^~\n]+)~~"#, kind: "strikethrough")
        }
        if !last { text.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
        let all = NSRange(location: 0, length: text.length)
        text.addAttribute(prefix, value: marker, range: all)
        let snapshot = NSAttributedString(attributedString: text)
        text.addAttribute(originalLine, value: line + (!last ? "\n" : ""), range: all)
        text.addAttribute(renderedLine, value: snapshot, range: all)
        return text
    }

    private static func renderListGroup(lines: [String], from i: inout Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let first = parseList(lines[i].trimmingCharacters(in: .whitespaces)) else { i += 1; return result }
        let kind = first.kind
        var shared: NSTextList?
        if kind == .bullet {
            shared = NSTextList(markerFormat: .disc, options: 0)
        } else if kind == .ordered {
            let start = Int(first.marker.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) ?? 1
            shared = NSTextList(markerFormat: .decimal, options: [], startingItemNumber: start)
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !isLiteral(line), let info = parseList(trimmed), info.kind == kind else { break }
            var list = shared
            if kind == .task {
                let done = info.marker.lowercased().contains("[x]")
                list = TaskMarkerList(checked: done)
            }
            guard let list else { break }
            let last = i == lines.count - 1
            result.append(renderListItem(content: info.content, marker: info.marker, list: list, source: line, last: last))
            i += 1
        }
        return result
    }

    private static func renderListItem(content: String, marker: String, list: NSTextList, source: String, last: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(string: content, attributes: baseAttributes)
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.font, value: font(level: 0), range: full)
        inline(text, pattern: #"`([^`\n]+)`"#, kind: "code")
        inline(text, pattern: #"\[([^\]\n]+)\]\(([^\s)]+)\)"#, kind: "link")
        inline(text, pattern: #"\*\*([^*\n]+)\*\*"#, kind: "bold")
        inline(text, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, kind: "italic")
        inline(text, pattern: #"~~([^~\n]+)~~"#, kind: "strikethrough")
        let ps = NSMutableParagraphStyle()
        ps.textLists = [list]
        ps.lineSpacing = 2
        ps.paragraphSpacing = 2
        ps.headIndent = 24
        ps.firstLineHeadIndent = 16
        text.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: text.length))
        if !last { text.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
        let all = NSRange(location: 0, length: text.length)
        text.addAttribute(prefix, value: marker, range: all)
        let snapshot = NSAttributedString(attributedString: text)
        text.addAttribute(originalLine, value: source + (!last ? "\n" : ""), range: all)
        text.addAttribute(renderedLine, value: snapshot, range: all)
        return text
    }

    private static func renderQuoteGroup(lines: [String], from i: inout Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("> ") else { break }
            let content = String(trimmed.dropFirst(2))
            let last = i == lines.count - 1
            result.append(renderQuoteLine(content: content, marker: "> ", source: line, last: last))
            i += 1
        }
        return result
    }

    private static func renderQuoteLine(content: String, marker: String, source: String, last: Bool) -> NSAttributedString {
        let theme = ThemeRegistry.shared.current
        let text = NSMutableAttributedString(string: content, attributes: baseAttributes)
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.font, value: NSFontManager.shared.convert(font(level: 0), toHaveTrait: .italicFontMask), range: full)
        text.addAttribute(.foregroundColor, value: theme.style(for: .blockquote).foreground ?? theme.sidebarAccent, range: full)
        inline(text, pattern: #"`([^`\n]+)`"#, kind: "code")
        inline(text, pattern: #"\[([^\]\n]+)\]\(([^\s)]+)\)"#, kind: "link")
        inline(text, pattern: #"\*\*([^*\n]+)\*\*"#, kind: "bold")
        inline(text, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, kind: "italic")
        inline(text, pattern: #"~~([^~\n]+)~~"#, kind: "strikethrough")
        let ps = RichTextBlockStyle(
            padding: .init(leading: 12),
            border: .init(leading: 3),
            borderColor: theme.sidebarAccent.withAlphaComponent(0.7),
            backgroundColor: theme.sidebarAccent.withAlphaComponent(0.06)
        ).makeParagraphStyle()
        text.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: text.length))
        if !last { text.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
        let all = NSRange(location: 0, length: text.length)
        text.addAttribute(prefix, value: marker, range: all)
        let snapshot = NSAttributedString(attributedString: text)
        text.addAttribute(originalLine, value: source + (!last ? "\n" : ""), range: all)
        text.addAttribute(renderedLine, value: snapshot, range: all)
        return text
    }

    /// Render a fenced code block with its fences hidden: the visible text is the
    /// syntax-highlighted code only. The opening fence, full original source, and
    /// a pristine snapshot are stored as metadata so `source()` round-trips.
    private static func renderFencedBlock(lines: [String], from start: Int, fence: String, language: String,
                                          closeIndex: Int, hasClose: Bool) -> NSAttributedString {
        let codeEnd = hasClose ? closeIndex : lines.count
        let code = lines[(start + 1)..<codeEnd].joined(separator: "\n")
        let block = highlightCodeBlock(code, language: language)
        let all = NSRange(location: 0, length: block.length)
        let snapshot = NSAttributedString(attributedString: block)
        block.addAttribute(literalLine, value: true, range: all)
        block.addAttribute(codeFence, value: lines[start].trimmingCharacters(in: .whitespaces), range: all)
        let blockSource = lines[start...closeIndex].joined(separator: "\n") + (closeIndex < lines.count - 1 ? "\n" : "")
        block.addAttribute(originalBlock, value: blockSource, range: all)
        block.addAttribute(renderedBlock, value: snapshot, range: all)
        return block
    }

    /// Syntax-highlight fenced code with the theme's tree-sitter scopes, layered
    /// over the editor monospace font and the theme's code-block background.
    private static func highlightCodeBlock(_ code: String, language: String) -> NSMutableAttributedString {
        let theme = ThemeRegistry.shared.current
        let mono = ThemeSettings.shared.resolvedMonoFont
        let background = theme.style(for: .codeBlock).background ?? theme.editorBackground
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: mono,
            .foregroundColor: theme.editorForeground
        ])
        let engine = TreeSitterEngine()
        let aliases = ["javascript": "js", "typescript": "ts", "python": "py", "ruby": "rb",
                       "shell": "sh", "bash": "sh", "zsh": "sh", "swift": "swift"]
        let ext = aliases[language.lowercased()] ?? language.lowercased()
        if engine.setLanguage(forExtension: ext) {
            let range = NSRange(location: 0, length: result.length)
            for token in engine.tokenize(code, in: range) where NSMaxRange(token.range) <= result.length {
                if let color = theme.style(for: token.scope).foreground {
                    result.addAttribute(.foregroundColor, value: color, range: token.range)
                }
            }
        }
        // Native code block — a bordered, padded NSTextBlock instead of a flat
        // background fill. The block is a real rich-text structure; the markdown
        // round-trip survives because `semantic()` strips paragraph styles.
        let paragraph = RichTextBlockStyle(
            padding: .init(uniform: 12),
            border: .init(uniform: 1),
            borderColor: theme.rulerSeparator.withAlphaComponent(0.4),
            backgroundColor: background
        ).makeParagraphStyle(paragraphSpacing: 6)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Only explicitly file-backed images; remote Markdown never triggers a network fetch.
    private static func localImage(_ source: String) -> NSAttributedString? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[[^\]]*\]\((file://[^)]+)\)$"#),
              let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)),
              let url = URL(string: (source as NSString).substring(with: match.range(at: 1))), url.isFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10_000_000,
              let image = NSImage(contentsOf: url) else { return nil }
        let scale = min(1, 360 / max(image.size.width, 1))
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.addAttribute(imageSource, value: source, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func inline(_ text: NSMutableAttributedString, pattern: String, kind: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            if text.attribute(inlineCode, at: match.range.location, effectiveRange: nil) != nil { continue }
            let content = NSMutableAttributedString(attributedString: text.attributedSubstring(from: match.range(at: 1)))
            let range = NSRange(location: 0, length: content.length)
            if kind == "code" {
                content.addAttribute(inlineCode, value: true, range: range)
                content.addAttribute(.font, value: ThemeSettings.shared.resolvedMonoFont, range: range)
            } else if kind == "link" {
                let destination = (text.string as NSString).substring(with: match.range(at: 2))
                content.addAttribute(.link, value: destination, range: range)
            } else if kind == "strikethrough" {
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                let font = content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? self.font(level: 0)
                content.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: kind == "bold" ? .boldFontMask : .italicFontMask), range: range)
            }
            text.replaceCharacters(in: match.range, with: content)
        }
    }

    // MARK: - Source reconstruction

    static func source(_ content: NSAttributedString) -> String {
        let ns = content.string as NSString
        var output = ""
        var location = 0
        while location < ns.length {
            let paragraph = ns.lineRange(for: NSRange(location: location, length: 0))

            // Fenced code block — fences are hidden; reconstruct from metadata.
            if let fence = content.attribute(codeFence, at: location, effectiveRange: nil) as? String {
                var end = NSMaxRange(paragraph)
                var probe = location
                while probe < ns.length, content.attribute(codeFence, at: probe, effectiveRange: nil) != nil {
                    end = NSMaxRange(ns.lineRange(for: NSRange(location: probe, length: 0)))
                    probe = end
                }
                let blockRange = NSRange(location: location, length: end - location)
                let clean = NSMutableAttributedString(attributedString: content.attributedSubstring(from: blockRange))
                let cleanAll = NSRange(location: 0, length: clean.length)
                clean.removeAttribute(codeFence, range: cleanAll)
                clean.removeAttribute(originalBlock, range: cleanAll)
                clean.removeAttribute(renderedBlock, range: cleanAll)
                clean.removeAttribute(literalLine, range: cleanAll)
                if let snapshot = content.attribute(renderedBlock, at: location, effectiveRange: nil) as? NSAttributedString,
                   semantic(clean).isEqual(to: semantic(snapshot)),
                   let original = content.attribute(originalBlock, at: location, effectiveRange: nil) as? String {
                    output += original
                } else {
                    let raw = clean.string
                    let code = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
                    let closing = String(fence.prefix(3))
                    output += fence + "\n" + code + "\n" + closing
                    if raw.hasSuffix("\n") { output += "\n" }
                }
                location = end
                continue
            }

            // Table block.
            if let style = content.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
               let first = style.textBlocks.first as? NSTextTableBlock {
                let divider = content.attribute(tableDivider, at: location, effectiveRange: nil) as? String
                var rows: [Int: [Int: String]] = [:]
                while location < ns.length {
                    let range = ns.lineRange(for: NSRange(location: location, length: 0))
                    guard let p = content.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
                          let block = p.textBlocks.first as? NSTextTableBlock, block.table === first.table else { break }
                    let cell = NSMutableAttributedString(attributedString: content.attributedSubstring(from: range))
                    cell.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: cell.length))
                    let value = source(cell).trimmingCharacters(in: .newlines).replacingOccurrences(of: "|", with: "\\|")
                    rows[block.startingRow, default: [:]][block.startingColumn, default: ""] += value
                    location = NSMaxRange(range)
                }
                for row in rows.keys.sorted() {
                    let values = (0..<first.table.numberOfColumns).map { rows[row]?[$0] ?? "" }
                    output += "| " + values.joined(separator: " | ") + " |\n"
                    if row == rows.keys.min() {
                        output += (divider ?? ("| " + Array(repeating: "---", count: first.table.numberOfColumns).joined(separator: " | ") + " |")) + "\n"
                    }
                }
                continue
            }

            // Normal line.
            let literal = ns.substring(with: paragraph)
            let marker = content.attribute(prefix, at: location, effectiveRange: nil) as? String ?? ""
            let clean = NSMutableAttributedString(attributedString: content.attributedSubstring(from: paragraph))
            let all = NSRange(location: 0, length: clean.length)
            clean.removeAttribute(originalLine, range: all)
            clean.removeAttribute(renderedLine, range: all)
            if let snapshot = content.attribute(renderedLine, at: location, effectiveRange: nil) as? NSAttributedString,
               semantic(clean).isEqual(to: semantic(snapshot)),
               let original = content.attribute(originalLine, at: location, effectiveRange: nil) as? String {
                output += original
                location = NSMaxRange(paragraph)
                continue
            }
            output += marker
            if content.attribute(literalLine, at: location, effectiveRange: nil) != nil {
                output += literal
            } else {
                content.enumerateAttributes(in: paragraph) { attrs, range, _ in
                    let text = ns.substring(with: range)
                    if let image = attrs[imageSource] as? String { output += image; return }
                    guard text != "\n" else { output += text; return }
                    let newline = text.hasSuffix("\n") ? "\n" : ""
                    var value = newline.isEmpty ? text : String(text.dropLast())
                    if attrs[inlineCode] != nil { value = "`" + value + "`" }
                    else {
                        let font = attrs[.font] as? NSFont ?? self.font(level: 0)
                        let traits = NSFontManager.shared.traits(of: font)
                        if traits.contains(.italicFontMask) { value = "*" + value + "*" }
                        if traits.contains(.boldFontMask) && !marker.hasPrefix("#") { value = "**" + value + "**" }
                        if attrs[.strikethroughStyle] != nil { value = "~~" + value + "~~" }
                        if let link = attrs[.link] { value = "[" + value + "](" + String(describing: link) + ")" }
                    }
                    output += value + newline
                }
            }
            location = NSMaxRange(paragraph)
        }
        return output
    }

    private static func semantic(_ source: NSAttributedString) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: source)
        let all = NSRange(location: 0, length: value.length)
        value.removeAttribute(.foregroundColor, range: all)
        value.removeAttribute(.backgroundColor, range: all)
        value.removeAttribute(.paragraphStyle, range: all)
        source.enumerateAttribute(.font, in: all) { font, range, _ in
            value.removeAttribute(.font, range: range)
            if let font = font as? NSFont {
                value.addAttribute(NSAttributedString.Key("aether.traits"),
                                   value: NSFontManager.shared.traits(of: font).rawValue, range: range)
            }
        }
        return value
    }
}