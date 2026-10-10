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
}

// MARK: - Document

/// State for one diff opened as a first-class tab. The view renders the parsed
/// `lines`; the raw unified text is retained for the editable "raw" mode and for
/// copying back out to the clipboard.
final class DiffDocument: ObservableObject {
    @Published var title: String
    @Published var subtitle: String
    @Published var lines: [DiffLine] = []
    @Published var rawText: String = ""
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
        self.lines = DiffParser.parse(diff)
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

    // Metrics
    private var monoFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private var monoSwiftUIFont: Font { .system(size: 12, design: .monospaced) }
    private var lineHeight: CGFloat { EditorGutterStyle.measuredLineHeight(for: monoFont, lineSpacing: 0) + 2 }
    private var charWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: monoFont]).width }
    private var oldColWidth: CGFloat { CGFloat(max(2, String(document.maxOldLine).count)) * charWidth + 18 }
    private var newColWidth: CGFloat { CGFloat(max(2, String(document.maxNewLine).count)) * charWidth + 18 }
    private let signColWidth: CGFloat = 16

    /// Leading column span of the unified diff — the `24` content inset plus the
    /// two line-number columns and the sign column. Shared so the titlebar can
    /// indent the title past the double line-number column exactly as it does for
    /// the code gutter and the rich-text ruler.
    static func leadingGutterWidth(for document: DiffDocument) -> CGFloat {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: monoFont]).width
        let old = CGFloat(max(2, String(document.maxOldLine).count)) * charWidth + 18
        let new = CGFloat(max(2, String(document.maxNewLine).count)) * charWidth + 18
        return 24 + old + new + 16
    }

    private var accent: Color { Color(nsColor: theme.sidebarAccent) }
    private var foreground: Color { Color(nsColor: theme.editorForeground) }
    private var addColor: Color { Color(nsColor: .systemGreen) }
    private var removeColor: Color { Color(nsColor: .systemRed) }
    private var separatorColor: Color { Color(nsColor: theme.rulerSeparator) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                theme.editorBackgroundColor.ignoresSafeArea()

                if isEditing {
                    rawEditor
                } else {
                    diffScroll
                }

                header
            }
            .padding(.leading, leading)
            .padding(.trailing, trailing)
        }
    }

    // MARK: Layers

    private var diffScroll: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.lines) { line in
                    DiffRow(line: line,
                            theme: theme,
                            oldColWidth: oldColWidth,
                            newColWidth: newColWidth,
                            signColWidth: signColWidth,
                            font: monoSwiftUIFont,
                            lineHeight: lineHeight)
                }
            }
            .padding(.top, topInset + 60)
            .padding(.bottom, 40)
            .padding(.leading, 24)
            .padding(.trailing, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom, .leading, .trailing])
        .scrollIndicators(.visible)
    }

    private var rawEditor: some View {
        TextEditor(text: $document.rawText)
            .font(monoSwiftUIFont)
            .foregroundStyle(foreground)
            .scrollContentBackground(.hidden)
            .padding(.top, topInset + 60)
            .padding(.bottom, 24)
            .padding(.horizontal, 24)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(document.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if !document.subtitle.isEmpty {
                Text(document.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider().frame(height: 14)

            Text("+\(document.addedCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(addColor)
            Text("−\(document.removedCount)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(removeColor)

            Divider().frame(height: 14)

            Button { copyRaw() } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Copy unified diff")

            if let filePath = document.filePath {
                Button { openExternally(filePath) } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Open in external editor")
            }

            Button { isEditing.toggle() } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(isEditing ? "Done editing" : "Edit raw diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .padding(.top, topInset + 48)
        .padding(.trailing, 20)
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
    let oldColWidth: CGFloat
    let newColWidth: CGFloat
    let signColWidth: CGFloat
    let font: Font
    let lineHeight: CGFloat

    private var accent: Color { Color(nsColor: theme.sidebarAccent) }
    private var foreground: Color { Color(nsColor: theme.editorForeground) }
    private var addColor: Color { Color(nsColor: .systemGreen) }
    private var removeColor: Color { Color(nsColor: .systemRed) }

    var body: some View {
        HStack(spacing: 0) {
            numberCell(line.oldNo, width: oldColWidth, color: oldNumberColor)
            numberCell(line.newNo, width: newColWidth, color: newNumberColor)
            signCell
            contentCell
        }
        .frame(height: lineHeight, alignment: .top)
        .background(rowBackground)
    }

    private func numberCell(_ number: Int?, width: CGFloat, color: Color) -> some View {
        Text(number.map(String.init) ?? "")
            .font(font)
            .foregroundStyle(color)
            .frame(width: width, height: lineHeight, alignment: .topTrailing)
            .padding(.trailing, 6)
    }

    @ViewBuilder private var signCell: some View {
        Text(line.sign.map(String.init) ?? "")
            .font(font)
            .foregroundStyle(signColor)
            .frame(width: signColWidth, height: lineHeight, alignment: .topLeading)
    }

    private var contentCell: some View {
        Text(contentText)
            .font(font)
            .foregroundStyle(contentColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 12)
    }

    private var contentText: String {
        var s = ""
        if let sign = line.sign { s += String(sign) }
        s += line.text
        return s.isEmpty ? " " : s
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

    private var oldNumberColor: Color {
        line.kind == .remove ? removeColor.opacity(0.75) : foreground.opacity(0.45)
    }

    private var newNumberColor: Color {
        line.kind == .add ? addColor.opacity(0.75) : foreground.opacity(0.45)
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