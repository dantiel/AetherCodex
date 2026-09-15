import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Separate storage prevents the syntax highlighter from destroying rich attributes.
final class RichTextDocument: NSObject, ObservableObject, NSTextViewDelegate {
    @Published var active = false
    @Published var markdown = false
    @Published var paperColor = NSColor.white
    /// Bumped whenever the attributed content changes, so SwiftUI re-measures
    /// the layout extent of the SwiftUI-owned scroll surface.
    @Published private(set) var contentRevision = 0
    /// Bumped on every selection change so the formatting toolbar can reflect
    /// the active traits (bold/italic/underline/list) without polling.
    @Published private(set) var selectionRevision = 0
    let textView = NSTextView()
    private var original = Data()
    private var edited = false
    var onChange: (() -> Void)?
    private var appearanceSignature = ""

    func refreshTheme() {
        guard active, markdown, let storage = textView.textStorage else { return }
        let theme = ThemeRegistry.shared.current
        let settings = ThemeSettings.shared
        let signature = "\(theme.name)|\(settings.resolvedProportionalFont)|\(settings.resolvedMonoFont)"
        guard signature != appearanceSignature else { return }
        appearanceSignature = signature
        let copy = NSAttributedString(attributedString: storage)
        storage.beginEditing()
        copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attrs, range, _ in
            let marker = attrs[MarkdownRichCodec.prefix] as? String ?? ""
            let level = marker.prefix(while: { $0 == "#" }).count
            let isCode = attrs[MarkdownRichCodec.inlineCode] != nil || attrs[MarkdownRichCodec.literalLine] != nil
            var font = isCode ? settings.resolvedMonoFont : MarkdownRichCodec.font(level: level)
            if let old = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: old).intersection([.boldFontMask, .italicFontMask])
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            let scope: TokenScope = attrs[.link] != nil ? .link : level > 0
                ? TokenScope(rawValue: "markup.heading.\(level)") ?? .heading : .markup
            storage.addAttributes([.font: font, .foregroundColor: theme.style(for: scope).foreground ?? theme.editorForeground], range: range)
        }
        storage.endEditing()
        contentRevision += 1
    }

    override init() {
        super.init()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 32, height: 28)
        textView.delegate = self
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
    }

    func load(_ data: Data, markdown: Bool) throws {
        let content: NSAttributedString
        if markdown {
            guard let source = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            content = MarkdownRichCodec.render(source)
        } else {
            var attributes: NSDictionary?
            content = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                             documentAttributes: &attributes)
            paperColor = attributes?[NSAttributedString.DocumentAttributeKey.backgroundColor] as? NSColor ?? .white
        }
        textView.textStorage?.setAttributedString(content)
        textView.typingAttributes = MarkdownRichCodec.baseAttributes
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        original = data
        edited = false
        self.markdown = markdown
        active = true
        appearanceSignature = ""
        refreshTheme()
        contentRevision += 1
    }

    func encoded() throws -> Data {
        if !edited { return original }
        let content = textView.attributedString()
        if markdown { return Data(MarkdownRichCodec.source(content).utf8) }
        return try content.data(from: NSRange(location: 0, length: content.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func textDidChange(_ notification: Notification) {
        edited = true
        onChange?()
        contentRevision += 1
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionRevision += 1
    }

    /// TextKit 1 layout height for the wrapping rich-text view at `width`.
    /// Measured on the document's own layout manager so the SwiftUI `ScrollView`
    /// can own the scroll and let `.scrollEdgeEffectStyle` blur natively.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return 0 }
        let previous = container.containerSize
        container.containerSize = NSSize(width: max(width - textView.textContainerInset.width * 2, 1), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        container.containerSize = previous
        return ceil(used.height + textView.textContainerInset.height * 2)
    }

    func trait(_ trait: NSFontTraitMask) {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? ThemeSettings.shared.resolvedProportionalFont
            let enabled = NSFontManager.shared.traits(of: font).contains(trait)
            textView.typingAttributes[.font] = enabled
                ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
            textView.window?.makeFirstResponder(textView)
            return
        }
        transform(selection) { content in
            let font = content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? ThemeSettings.shared.resolvedProportionalFont
            let remove = NSFontManager.shared.traits(of: font).contains(trait)
            content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                let font = value as? NSFont ?? ThemeSettings.shared.resolvedProportionalFont
                content.addAttribute(.font, value: remove ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                                     : NSFontManager.shared.convert(font, toHaveTrait: trait), range: range)
            }
        }
    }

    // MARK: - Formatting (TextEdit-style toolbar)

    var currentAttributes: [NSAttributedString.Key: Any] {
        let selection = textView.selectedRange()
        if selection.length == 0 { return textView.typingAttributes }
        guard textView.attributedString().length > selection.location else { return textView.typingAttributes }
        return textView.attributedString().attributes(at: selection.location, effectiveRange: nil)
    }

    var currentFont: NSFont {
        currentAttributes[.font] as? NSFont ?? ThemeSettings.shared.resolvedProportionalFont
    }

    func toggleAttribute(_ key: NSAttributedString.Key, value: Any) {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            if textView.typingAttributes[key] != nil { textView.typingAttributes.removeValue(forKey: key) }
            else { textView.typingAttributes[key] = value }
            selectionRevision += 1
            textView.window?.makeFirstResponder(textView)
            return
        }
        transform(selection) { content in
            let range = NSRange(location: 0, length: content.length)
            if content.attribute(key, at: 0, effectiveRange: nil) != nil {
                content.removeAttribute(key, range: range)
            } else {
                content.addAttribute(key, value: value, range: range)
            }
        }
        selectionRevision += 1
    }

    func setTextColor(_ color: NSColor) {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            textView.typingAttributes[.foregroundColor] = color
            textView.window?.makeFirstResponder(textView)
            return
        }
        transform(selection) { content in
            content.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: content.length))
        }
    }

    func setFontFamily(_ name: String) {
        let size = currentFont.pointSize
        let font: NSFont
        if name == "System" {
            font = NSFont.systemFont(ofSize: size)
        } else if let members = NSFontManager.shared.availableMembers(ofFontFamily: name),
                  let first = members.first, let ps = first.first as? String,
                  let resolved = NSFont(name: ps, size: size) {
            font = resolved
        } else {
            font = NSFont(name: name, size: size) ?? currentFont
        }
        applyFont { _ in font }
    }

    func setFontSize(_ size: CGFloat) {
        applyFont { NSFontManager.shared.convert($0, toSize: size) }
    }

    private func applyFont(_ convert: (NSFont) -> NSFont) {
        let selection = textView.selectedRange()
        if selection.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? ThemeSettings.shared.resolvedProportionalFont
            textView.typingAttributes[.font] = convert(font)
            textView.window?.makeFirstResponder(textView)
            return
        }
        transform(selection) { content in
            content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                let font = value as? NSFont ?? ThemeSettings.shared.resolvedProportionalFont
                content.addAttribute(.font, value: convert(font), range: range)
            }
        }
    }

    func insertList(kind: MarkdownRichCodec.ListKind) {
        let selection = textView.selectedRange()
        let range = (textView.string as NSString).paragraphRange(for: selection)
        if !markdown {
            let list: NSTextList
            switch kind {
            case .bullet: list = NSTextList(markerFormat: .disc, options: 0)
            case .ordered: list = NSTextList(markerFormat: .decimal, options: 0)
            case .task: list = NSTextList(markerFormat: .box, options: 0)
            }
            applyBlockStyle(to: range) { style in
                style.textLists = [list]
                style.headIndent = 24
                style.firstLineHeadIndent = 16
            }
            return
        }
        let marker: String
        switch kind {
        case .bullet: marker = "- "
        case .ordered: marker = "1. "
        case .task: marker = "- [ ] "
        }
        let selected = (textView.string as NSString).substring(with: range)
        let text = marker + selected.replacingOccurrences(of: "\n", with: "\n" + marker)
        textView.insertText(NSAttributedString(string: text, attributes: MarkdownRichCodec.baseAttributes), replacementRange: range)
        textView.window?.makeFirstResponder(textView)
    }

    func insertQuote() {
        let selection = textView.selectedRange()
        let range = (textView.string as NSString).paragraphRange(for: selection)
        if !markdown {
            let theme = ThemeRegistry.shared.current
            applyBlockStyle(to: range) { style in
                style.textBlocks = [RichTextBlockStyle(
                    padding: .init(leading: 12),
                    border: .init(leading: 3),
                    borderColor: theme.sidebarAccent.withAlphaComponent(0.7),
                    backgroundColor: theme.sidebarAccent.withAlphaComponent(0.06)
                ).makeBlock()]
            }
            return
        }
        let marker = "> "
        let selected = (textView.string as NSString).substring(with: range)
        let text = marker + selected.replacingOccurrences(of: "\n", with: "\n" + marker)
        textView.insertText(NSAttributedString(string: text, attributes: MarkdownRichCodec.baseAttributes), replacementRange: range)
        textView.window?.makeFirstResponder(textView)
    }

    func insertCodeBlock() {
        let selection = textView.selectedRange()
        let range = (textView.string as NSString).paragraphRange(for: selection)
        if !markdown {
            let theme = ThemeRegistry.shared.current
            transform(range) { content in
                let all = NSRange(location: 0, length: content.length)
                content.addAttribute(.font, value: ThemeSettings.shared.resolvedMonoFont, range: all)
                let style = RichTextBlockStyle(
                    padding: .init(uniform: 12),
                    border: .init(uniform: 1),
                    borderColor: theme.rulerSeparator.withAlphaComponent(0.4),
                    backgroundColor: theme.style(for: .codeBlock).background ?? theme.editorBackground
                ).makeParagraphStyle(paragraphSpacing: 6)
                content.addAttribute(.paragraphStyle, value: style, range: all)
            }
            return
        }
        let selected = (textView.string as NSString).substring(with: range)
        let text = "```\n" + selected + "\n```"
        textView.insertText(NSAttributedString(string: text, attributes: MarkdownRichCodec.baseAttributes), replacementRange: range)
        textView.window?.makeFirstResponder(textView)
    }

    func paragraph(_ level: Int) {
        let range = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        guard range.length > 0 else { return }
        transform(range) { content in
            let all = NSRange(location: 0, length: content.length)
            content.addAttribute(.font, value: MarkdownRichCodec.font(level: level), range: all)
            if markdown {
                let scope = TokenScope(rawValue: "markup.heading.\(level)") ?? .markup
                content.addAttribute(.foregroundColor, value: ThemeRegistry.shared.current.style(for: scope).foreground
                                     ?? ThemeRegistry.shared.current.editorForeground, range: all)
                content.addAttribute(MarkdownRichCodec.prefix, value: level == 0 ? "" : String(repeating: "#", count: level) + " ", range: all)
            } else if level > 0 {
                let style = NSMutableParagraphStyle()
                style.headerLevel = level
                style.lineSpacing = 2
                style.paragraphSpacing = 4
                content.addAttribute(.paragraphStyle, value: style, range: all)
            }
        }
    }

    /// Applies a paragraph-style mutation to the selected paragraph(s) without
    /// clobbering an existing style — used by native block insertion in RTF mode.
    private func applyBlockStyle(to range: NSRange, mutate: (NSMutableParagraphStyle) -> Void) {
        guard range.length > 0 else { return }
        transform(range) { content in
            let all = NSRange(location: 0, length: content.length)
            let existing = content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 2
            mutate(style)
            content.addAttribute(.paragraphStyle, value: style, range: all)
        }
    }

    func insertTable() {
        textView.insertText(RichTextTable.make([["Column 1", "Column 2"], ["Value", "Value"]]),
                            replacementRange: textView.selectedRange())
        textView.window?.makeFirstResponder(textView)
    }

    func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        let attachment = NSTextAttachment()
        let scale = min(1, 360 / max(image.size.width, 1))
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        let content = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        if markdown {
            content.addAttribute(MarkdownRichCodec.imageSource, value: "![Image](\(url.absoluteString))",
                                 range: NSRange(location: 0, length: content.length))
        }
        textView.insertText(content, replacementRange: textView.selectedRange())
        textView.typingAttributes = MarkdownRichCodec.baseAttributes
        textView.window?.makeFirstResponder(textView)
    }

    func toggleTask() {
        let range = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        guard let storage = textView.textStorage,
              let original = storage.attribute(MarkdownRichCodec.originalLine, at: range.location, effectiveRange: nil) as? String else { return }
        let line = original.trimmingCharacters(in: .newlines)
        let lower = line.lowercased()
        guard lower.hasPrefix("- [") || lower.hasPrefix("* [") || lower.hasPrefix("+ [") else { return }
        let completing = lower.contains("[ ]")

        var updated = line
        if completing {
            updated = updated.replacingOccurrences(of: "[ ]", with: "[x]", options: .caseInsensitive)
            if !updated.contains("@done(") {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                updated += " @done(" + formatter.string(from: Date()) + ")"
            }
        } else {
            updated = updated.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive)
            if let r = updated.range(of: #"\s@done\([^)]*\)"#, options: .regularExpression) {
                updated.removeSubrange(r)
            }
        }

        let hadNewline = original.hasSuffix("\n")
        textView.insertText(MarkdownRichCodec.render(updated + (hadNewline ? "\n" : "")), replacementRange: range)
        textView.window?.makeFirstResponder(textView)
    }

    private func transform(_ range: NSRange, change: (NSMutableAttributedString) -> Void) {
        let content = NSMutableAttributedString(attributedString: textView.attributedString().attributedSubstring(from: range))
        change(content)
        textView.insertText(content, replacementRange: range)
        textView.setSelectedRange(range)
        textView.window?.makeFirstResponder(textView)
    }
}

struct RichTextSurface: View {
    @ObservedObject var document: RichTextDocument
    let theme: SyntaxTheme
    let showSource: () -> Void
    /// Whether the file-browser sidebar is closed — when true, the ruler is the
    /// leftmost surface and fades in under the transparent titlebar, matching
    /// the code editor's gutter.
    var sidebarClosed: Bool = false

    /// Real scroll-content breathing room below the floating controls bar.
    /// It scrolls away with the text (like the source surface), so the native
    /// `.scrollEdgeEffectStyle` from `EditorContainerView` progressively blurs
    /// the document as it travels beneath the transparent top bar.
    private let topContentInset: CGFloat = 96

    /// Fixed leading margin strip (the "side ruler") flush against the left
    /// sidebar. Mirrors the line-number gutter's glass surface and colors,
    /// minus the numbers.
    private let rulerWidth: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let viewportTextWidth = max(proxy.size.width - rulerWidth, 1)
            let measured = document.contentHeight(forWidth: viewportTextWidth)
            let renderedHeight = max(measured, proxy.size.height - topContentInset)
            let baseFont = MarkdownRichCodec.font(level: 0)
            let lineHeight = baseFont.ascender - baseFont.descender + baseFont.leading + 2
            let textTopInset = document.textView.textContainerInset.height

            ZStack(alignment: .topLeading) {
                (document.markdown ? theme.editorBackgroundColor : Color(nsColor: document.paperColor))

                // Fixed gutter surface — pinned BEHIND the scroll content. It never
                // scrolls, so it must never blur; only the measure ticks (which sit
                // above it inside the scroll) participate in the top scroll-edge blur.
                RichTextRulerBackground(theme: theme, width: rulerWidth, sidebarClosed: sidebarClosed)
                    .frame(width: rulerWidth, height: proxy.size.height,
                           alignment: .topLeading)
                    .allowsHitTesting(false)

                // SwiftUI owns the scroll — no AppKit NSScrollView. The measure ticks
                // live inside the scroll content beside the text, so they travel *with*
                // it (one frame of reference) and blur under the top bar together,
                // while the fixed gutter surface behind them stays crisp.
                ScrollView(.vertical, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        RichTextRuler(theme: theme, width: rulerWidth,
                                      height: renderedHeight,
                                      lineHeight: lineHeight, topInset: textTopInset)
                        RichTextEditorRepresentable(document: document, width: viewportTextWidth)
                            .frame(width: viewportTextWidth, height: renderedHeight)
                    }
                    .padding(.top, topContentInset)
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scrollIndicators(.visible)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .overlay(alignment: .top) {
            chrome
                .padding(.top, 36)
        }
    }

    /// Floating, transparent controls bar. No material backing — the document
    /// text passes behind it and participates in the top scroll-edge blur.
    private var chrome: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                controls
                ScrollView(.horizontal) { controls }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            // Quiet measure, not page chrome or line numbers.
            Canvas { context, size in
                for x in stride(from: 32.0, to: size.width - 24, by: 16) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: Int(x) % 64 == 32 ? 7 : 3))
                    context.stroke(path, with: .color(.secondary.opacity(0.28)), lineWidth: 1)
                }
            }.frame(height: 10).accessibilityHidden(true)
        }
    }
    // MARK: - Toolbar state

    private static let fontFamilies = ["System", "New York", "SF Pro Text", "Avenir Next",
                                       "Helvetica Neue", "Georgia", "Palatino", "Times New Roman",
                                       "Optima", "Hoefler Text", "Charter", "Futura", "Gill Sans",
                                       "Menlo", "Monaco", "SF Mono", "Courier New"]
    private static let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 36, 48, 64, 72]

    private var isBold: Bool { NSFontManager.shared.traits(of: document.currentFont).contains(.boldFontMask) }
    private var isItalic: Bool { NSFontManager.shared.traits(of: document.currentFont).contains(.italicFontMask) }
    private var isUnderline: Bool { document.currentAttributes[.underlineStyle] != nil }
    private var isStrikethrough: Bool { document.currentAttributes[.strikethroughStyle] != nil }
    private var currentFamily: String { document.currentFont.familyName ?? document.currentFont.fontName }

    private func openFontPanel() {
        document.textView.window?.makeFirstResponder(document.textView)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }
    private func openColorPanel() {
        document.textView.window?.makeFirstResponder(document.textView)
        NSColorPanel.shared.orderFront(nil)
    }

    private var controls: some View {
        HStack(spacing: 5) {
            // Format-aware chrome: only the capabilities the output document
            // actually serializes are offered. Markdown hides typographic controls
            // (font family/size, underline, colour) because they have no Markdown
            // syntax and would not survive the round-trip; RTF shows them all.
            if !document.markdown {
                // Font family + size — the TextEdit heart, in liquid glass.
                Menu {
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Button(family) { document.setFontFamily(family) }
                    }
                    Divider()
                    Button("Show Fonts…", action: openFontPanel)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "textformat")
                        Text(currentFamily).lineLimit(1)
                    }
                    .frame(minWidth: 104, alignment: .leading)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Font family")

                Menu {
                    ForEach(Self.fontSizes, id: \.self) { size in
                        Button("\(Int(size))") { document.setFontSize(size) }
                    }
                } label: {
                    Text("\(Int(document.currentFont.pointSize))").frame(minWidth: 20)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Font size")

                Divider().frame(height: 16)
            }

            GlyphToggle(system: "bold", active: isBold, help: "Bold") { document.trait(.boldFontMask) }
            GlyphToggle(system: "italic", active: isItalic, help: "Italic") { document.trait(.italicFontMask) }
            if !document.markdown {
                GlyphToggle(system: "underline", active: isUnderline, help: "Underline") { document.toggleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue) }
            }
            GlyphToggle(system: "strikethrough", active: isStrikethrough, help: "Strikethrough") { document.toggleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue) }
            if !document.markdown {
                GlyphToggle(system: "paintpalette", active: false, help: "Text color", action: openColorPanel)
            }

            Divider().frame(height: 16)

            GlyphToggle(system: "list.bullet", active: false, help: "Bullet list") { document.insertList(kind: .bullet) }
            GlyphToggle(system: "list.number", active: false, help: "Numbered list") { document.insertList(kind: .ordered) }
            GlyphToggle(system: "checklist", active: false, help: "Task list") { document.insertList(kind: .task) }
            if document.markdown {
                GlyphToggle(system: "checkmark.square", active: false, help: "Toggle task") { document.toggleTask() }
            }
            GlyphToggle(system: "text.quote", active: false, help: "Block quote") { document.insertQuote() }
            GlyphToggle(system: "chevron.left.forwardslash.chevron.right", active: false, help: "Code block") { document.insertCodeBlock() }

            Divider().frame(height: 16)

            Menu {
                Button("Body") { document.paragraph(0) }
                ForEach(1...3, id: \.self) { level in
                    Button("Heading \(level)") { document.paragraph(level) }
                }
            } label: {
                Image(systemName: "paragraphsign")
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .help("Paragraph style")

            Menu {
                Button("Table · 2 × 2") { document.insertTable() }
                Button("Local image…") { document.insertImage() }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .help("Insert")

            Spacer(minLength: 8)

            if document.markdown {
                Button(action: showSource) {
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Show Markdown source")
            } else {
                Button(action: openFontPanel) { Image(systemName: "textformat") }
                    .buttonStyle(LiquidGlassButtonStyle()).help("Fonts")
                Button(action: openColorPanel) { Image(systemName: "paintpalette") }
                    .buttonStyle(LiquidGlassButtonStyle()).help("Colors")
            }
        }
        .controlSize(.small)
    }
}

/// Liquid-glass toolbar button: frosted material, hairline stroke, soft shadow.
/// Press feedback is a subtle scale — chrome that dissolves into the work.
private struct LiquidGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.12), radius: 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A compact glyph toggle (bold/italic/underline/list/…) with an active tint.
private struct GlyphToggle: View {
    let system: String
    let active: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.8))
                .frame(width: 22, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(active ? 0.28 : 0.10), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RichTextEditorRepresentable: NSViewRepresentable {
    let document: RichTextDocument
    let width: CGFloat

    func makeNSView(context: Context) -> RichTextEditorView {
        let host = RichTextEditorView(frame: .zero)
        host.adopt(document.textView)
        return host
    }

    func updateNSView(_ nsView: RichTextEditorView, context: Context) {
        nsView.adopt(document.textView)
        nsView.layoutDocument(width: width)
    }
}

/// Bare, non-scrolling host for the rich-text `NSTextView`. It re-parents the
/// document's text view into itself (no `NSScrollView`), so a SwiftUI
/// `ScrollView` can size it to the measured content and own the scrolling —
/// which is what lets the native scroll-edge blur reach the text.
private final class RichTextEditorView: NSView {
    private(set) var editorTextView: NSTextView?

    override var isFlipped: Bool { true }

    func adopt(_ textView: NSTextView) {
        guard editorTextView !== textView else { return }
        editorTextView?.removeFromSuperview()
        textView.removeFromSuperview()
        textView.enclosingScrollView?.documentView = nil
        editorTextView = textView
        textView.drawsBackground = false
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        addSubview(textView)
        needsLayout = true
    }

    func layoutDocument(width: CGFloat) {
        guard let textView = editorTextView else { return }
        textView.frame = bounds
        textView.textContainer?.containerSize = NSSize(width: max(width - textView.textContainerInset.width * 2, 1), height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }

    override func layout() {
        super.layout()
        if let textView = editorTextView {
            textView.frame = bounds
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let textView = editorTextView { window?.makeFirstResponder(textView) }
        super.mouseDown(with: event)
    }
}

/// The *moving* part of the ruler: bare measure ticks, no surface. It lives
/// inside the scroll content beside the text view, so the ticks travel with the
/// text and participate in the top scroll-edge blur. Ticks are drawn at the live
/// line height — one minor tick per line, a major every five, a grand every ten —
/// so the ruler reads as a precise astronomer's measure, not a fixed decorative
/// gutter.
private struct RichTextRuler: View {
    let theme: SyntaxTheme
    let width: CGFloat
    var height: CGFloat = 0
    var lineHeight: CGFloat = 18
    var topInset: CGFloat = 28

    var body: some View {
        ticks
            .frame(width: width, height: height)
            .allowsHitTesting(false)
    }

    private var ticks: some View {
        Canvas { context, size in
            let minor = theme.rulerForeground.withAlphaComponent(0.20)
            let major = theme.rulerForeground.withAlphaComponent(0.42)
            let grand = theme.rulerForeground.withAlphaComponent(0.62)
            let step = lineHeight > 0 ? lineHeight : 18
            var line = 0
            var y = topInset
            while y < size.height {
                let isMajor = line % 5 == 0
                let isGrand = line % 10 == 0
                let length: CGFloat = isGrand ? 12 : isMajor ? 8 : 4
                var path = Path()
                path.move(to: CGPoint(x: size.width - 2 - length, y: y))
                path.addLine(to: CGPoint(x: size.width - 2, y: y))
                context.stroke(path,
                               with: .color(Color(nsColor: isGrand ? grand : isMajor ? major : minor)),
                               lineWidth: isGrand ? 1.2 : 1)
                y += step
                line += 1
            }
        }
    }
}

/// The *fixed* part of the ruler: the line-number gutter surface and separator,
/// pinned outside the scroll content at the leading edge. It is static by design,
/// so it must stay crisp — never scrolled, never progressively blurred.
private struct RichTextRulerBackground: View {
    let theme: SyntaxTheme
    let width: CGFloat
    var sidebarClosed: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Solid theme surface — the ruler backdrop and its divider stay crisp;
            // only the scrolling measure ticks participate in the scroll-edge blur.
            Color(nsColor: theme.rulerBackground)
            Color(nsColor: theme.rulerSeparator).frame(width: 1).frame(maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .mask { edgeMask }
        .allowsHitTesting(false)
    }

    /// Matches the code editor's gutter: with the file browser closed the ruler
    /// becomes the leftmost surface and fades in beneath the transparent titlebar;
    /// with the sidebar open it stays solid for continuity with that surface.
    @ViewBuilder
    private var edgeMask: some View {
        if sidebarClosed {
            VStack(spacing: 0) {
                Color.clear.frame(height: 28)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
                Color.black
            }
        } else {
            Color.black
        }
    }
}