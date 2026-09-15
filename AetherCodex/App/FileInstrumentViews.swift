import Cocoa
import SwiftUI

// MARK: - Lese- & Schnitt-Instrumente · das Orakel-Auge für read_file & patch_file

/// Derselbe Blick, den `file_overview` trägt, nun für die Lese- und Schnitt-
/// Instrumente: `read_file` und `patch_file` erscheinen nicht als rohes JSON,
/// sondern als *Spiegel* — die Datei, ihr Pfad, ihre Maße und (beim Schnitt)
/// der Eingriff selbst, in den Farben der Kammer.

enum FileInstrumentTool {
    static func isReadFile(_ name: String) -> Bool { name == "read_file" }
    static func isPatchFile(_ name: String) -> Bool { name == "patch_file" }
    static func isCreateFile(_ name: String) -> Bool { name == "create_file" }
    static func isRenameFile(_ name: String) -> Bool { name == "rename_file" }
    static func isUndoPatch(_ name: String) -> Bool { name == "undo_patch" }
}

// MARK: - Modelle

struct ReadFileArgs: Decodable {
    var path: String = ""
    var range: [Int] = []
    var lineNumbers: Bool = false

    enum CodingKeys: String, CodingKey { case path, range, lineNumbers = "line_numbers" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        range = (try? c.decode([Int].self, forKey: .range)) ?? []
        lineNumbers = (try? c.decode(Bool.self, forKey: .lineNumbers)) ?? false
    }
}

struct ReadFileResult: Decodable {
    var content: String?
    var error: String?

    enum CodingKeys: String, CodingKey { case content, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try? c.decode(String.self, forKey: .content)
        error = try? c.decode(String.self, forKey: .error)
    }
}

struct PatchFileArgs: Decodable {
    var path: String = ""
    var diff: String = ""

    enum CodingKeys: String, CodingKey { case path, diff }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        diff = (try? c.decode(String.self, forKey: .diff)) ?? ""
    }
}

struct PatchFileResult: Decodable {
    var ok: Bool?
    var error: String?

    enum CodingKeys: String, CodingKey { case ok, error }
}

// MARK: - Schnitt-Block

struct PatchBlock: Identifiable {
    let id = UUID()
    let startLine: String
    let removed: [String]
    let added: [String]
}

/// Zerlegt ein `patch_file`-Diff in seine SEARCH/REPLACE-Blöcke. Kein voller
/// Diff-Renderer — nur genug, damit der Eingriff als *Bedeutung* erscheint.
func parsePatchBlocks(_ diff: String) -> [PatchBlock] {
    let chunks = diff.components(separatedBy: "<<<<<<< SEARCH").dropFirst()
    var blocks: [PatchBlock] = []
    for raw in chunks {
        var startLine = ""
        var removed: [String] = []
        var added: [String] = []

        if let sl = raw.range(of: ":start_line:") {
            let rest = raw[sl.upperBound...]
            startLine = rest.split(separator: "\n", maxSplits: 1)
                .first?.trimmingCharacters(in: .whitespaces) ?? ""
        }

        if let eq = raw.range(of: "=======") {
            let searchPart = String(raw[..<eq.lowerBound])
            let replacePart = String(raw[eq.upperBound...])
            if let dash = searchPart.range(of: "-------") {
                removed = PatchBlock.blockLines(String(searchPart[dash.upperBound...]))
            } else {
                removed = PatchBlock.blockLines(searchPart)
            }
            added = PatchBlock.blockLines(replacePart).filter { !$0.hasPrefix(">>>>>>>") }
        }

        blocks.append(PatchBlock(startLine: startLine, removed: removed, added: added))
    }
    return blocks
}

private extension PatchBlock {
    static func blockLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n").filter {
            !$0.hasPrefix("<<<<<<<") && !$0.hasPrefix(">>>>>>>")
                && !$0.hasPrefix("=======") && !$0.hasPrefix("-------")
                && !$0.hasPrefix(":start_line:")
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

// MARK: - Hilfen

func sourceLanguage(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "swift": return "swift"
    case "rb": return "ruby"
    case "js", "jsx": return "javascript"
    case "ts", "tsx": return "typescript"
    case "py": return "python"
    case "sh", "zsh", "bash": return "shell"
    case "md", "markdown": return "markdown"
    case "yml", "yaml": return "yaml"
    case "json": return "json"
    case "html": return "html"
    case "css": return "css"
    case "coffee": return "coffeescript"
    case "": return "plaintext"
    default: return (path as NSString).pathExtension.lowercased()
    }
}

func humanBytes(_ bytes: Int) -> String {
    let b = Double(bytes)
    if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
    if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
    return "\(bytes) B"
}

// MARK: - Gemeinsame Kammer-Oberfläche

private struct InstrumentHeader: View {
    let glyph: String
    let title: String
    let subtitle: String
    let accent: Color
    let aura: Color
    var trailing: String? = nil
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.55), aura.opacity(0.10), .clear],
                                         center: .center, startRadius: 1, endRadius: 16))
                    .frame(width: 28, height: 28)
                    .scaleEffect(breathe ? 1.14 : 0.96)
                    .blur(radius: 1)
                    .opacity(breathe ? 0.9 : 0.55)
                Text(glyph).font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.05), in: Capsule())
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

private struct MirrorSurface: ViewModifier {
    let accent: Color
    let aura: Color

    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [accent.opacity(0.13), aura.opacity(0.07), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            )
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.14), lineWidth: 0.5))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: [accent.opacity(0.9), aura.opacity(0.5), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.5)
                    .padding(.vertical, 8)
            }
    }
}

// MARK: - read_file · Datei-Lesung

struct ReadFileView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    private var accent: Color { palette.accentColor }
    private var aura: Color { palette.complementaryColor }

    private var args: ReadFileArgs? {
        guard let d = chip.args.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReadFileArgs.self, from: d)
    }

    private var result: ReadFileResult? {
        guard let d = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReadFileResult.self, from: d)
    }

    private var path: String { args?.path ?? "" }
    private var lang: String { sourceLanguage(for: path) }
    private var text: String {
        let raw = result?.content ?? ""
        guard args?.lineNumbers == true else { return raw }
        return Self.stripLineNumberPrefixes(raw)
    }

    /// `Argonaut.with_line_numbers` prefixes every line with `N| ` when the
    /// oracle requested `line_numbers: true`. The gutter in
    /// `LineNumberedCodeView` is the single source of truth, so strip the
    /// baked-in prefixes to avoid two competing number systems.
    private static func stripLineNumberPrefixes(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            guard let pipe = line.firstIndex(of: "|") else { return line }
            let head = line[..<pipe]
            guard !head.isEmpty, head.allSatisfy({ $0.isNumber }) else { return line }
            var rest = String(line[line.index(after: pipe)...])
            if rest.first == " " { rest.removeFirst() }
            return rest
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InstrumentHeader(glyph: "🌘", title: "Datei-Lesung",
                             subtitle: (path as NSString).lastPathComponent,
                             accent: accent, aura: aura,
                             trailing: chip.done ? (text.isEmpty ? nil : humanBytes(text.utf8.count)) : nil)

            if let error = result?.error, !error.isEmpty {
                errorCard(error)
            } else {
                if !path.isEmpty {
                    FileLinkButton(path: path, accent: accent)
                }
                statRow
                if !text.isEmpty {
                    contentPane
                }
            }
        }
        .modifier(MirrorSurface(accent: accent, aura: aura))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var statRow: some View {
        HStack(spacing: 5) {
            StatChip(glyph: "✧", value: lang)
            if let r = args?.range, r.count == 2 {
                StatChip(glyph: "☷", value: "Z. \(r[0])–\(r[1])")
            }
            let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
            StatChip(glyph: "☰", value: "\(lineCount) Zeilen")
        }
    }

    private var contentPane: some View {
        LineNumberedCodeView(code: text, language: lang,
                             startLine: args?.range.first ?? 1,
                             maxHeight: 240,
                             background: palette.codeBackgroundColor.opacity(0.55))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 6) {
            Text("⚠️")
            Text(error)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - patch_file · Schnitt

struct PatchFileView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    private var accent: Color { palette.complementaryColor }
    private var aura: Color { palette.accentColor }

    private var args: PatchFileArgs? {
        guard let d = chip.args.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PatchFileArgs.self, from: d)
    }

    private var result: PatchFileResult? {
        guard let d = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PatchFileResult.self, from: d)
    }

    private var path: String { args?.path ?? "" }
    private var lang: String { sourceLanguage(for: path) }
    private var blocks: [PatchBlock] { parsePatchBlocks(args?.diff ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InstrumentHeader(glyph: "🩹", title: "Schnitt",
                             subtitle: (path as NSString).lastPathComponent,
                             accent: accent, aura: aura,
                             trailing: chip.done ? (result?.ok == true ? "vollzogen" : "fehlgeschlagen") : nil)

            if !path.isEmpty {
                FileLinkButton(path: path, accent: accent)
            }
            statRow

            if let error = result?.error, !error.isEmpty {
                errorCard(error)
            } else if !blocks.isEmpty {
                diffPane
            } else if chip.done, result?.ok == true {
                doneCard
            }
        }
        .modifier(MirrorSurface(accent: accent, aura: aura))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var statRow: some View {
        HStack(spacing: 5) {
            StatChip(glyph: "▣", value: "\(blocks.count) Schnitte")
            StatChip(glyph: "☰", value: "\((args?.diff ?? "").components(separatedBy: "\n").count) Diff-Zeilen")
            if chip.done {
                let ok = result?.ok == true
                StatChip(glyph: ok ? "✓" : "✕", value: ok ? "vollzogen" : "fehlgeschlagen")
            }
        }
    }

    /// Unified diff — one code pane, the same `LineNumberedCodeView` that
    /// `read_file` and `create_file` share. Removed lines carry `-`, added
    /// lines carry `+`, unchanged edge lines appear once. The split view below
    /// (`splitDiffPane`) is retained for a later configurable choice.
    private var diffPane: some View {
        LineNumberedCodeView(code: unifiedDiffText, language: lang,
                             startLine: 1, maxHeight: 220,
                             background: palette.codeBackgroundColor.opacity(0.55))
    }

    /// Builds a single unified diff stream from the parsed SEARCH/REPLACE
    /// blocks. Common leading/trailing lines are emitted once (context), so a
    /// changed line no longer shows twice as removed *and* added.
    private var unifiedDiffText: String {
        var out: [String] = []
        for (idx, block) in blocks.enumerated() {
            var header = "@@ Schnitt \(idx + 1)"
            if !block.startLine.isEmpty { header += " · Zeile \(block.startLine)" }
            header += " @@"
            out.append(header)

            var removed = block.removed
            var added = block.added

            var prefix = 0
            while prefix < removed.count, prefix < added.count,
                  removed[prefix] == added[prefix] {
                out.append(" \(removed[prefix])")
                prefix += 1
            }
            removed.removeFirst(prefix)
            added.removeFirst(prefix)

            var suffix = 0
            while suffix < removed.count, suffix < added.count,
                  removed[removed.count - 1 - suffix] == added[added.count - 1 - suffix] {
                suffix += 1
            }
            let midRemoved = removed.dropLast(suffix)
            let midAdded = added.dropLast(suffix)
            let tail = removed.suffix(suffix)

            for line in midRemoved { out.append("-\(line)") }
            for line in midAdded { out.append("+\(line)") }
            for line in tail { out.append(" \(line)") }
        }
        return out.joined(separator: "\n")
    }

    /// Split diff — the earlier rendering (removed block, then added block).
    /// Kept in the codebase; a future preference toggle may switch between
    /// `diffPane` and this view.
    private var splitDiffPane: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("Schnitt \(idx + 1)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(palette.accentColor)
                            if !block.startLine.isEmpty {
                                Text("· Zeile \(block.startLine)")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        ForEach(Array(block.removed.enumerated()), id: \.offset) { _, line in
                            diffLine(line, sign: "-", tint: .red)
                        }
                        ForEach(Array(block.added.enumerated()), id: \.offset) { _, line in
                            diffLine(line, sign: "+", tint: .green)
                        }
                    }
                    .padding(6)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 220)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background(palette.codeBackgroundColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.shineColor.opacity(0.22), lineWidth: 0.5))
    }

    private func diffLine(_ line: String, sign: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(sign)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 8, alignment: .leading)
            Text(highlightCode(line, language: lang))
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 3)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
    }

    private var doneCard: some View {
        HStack(spacing: 6) {
            Text("✓ ok")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.green.opacity(0.20), lineWidth: 0.5))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 6) {
            Text("⚠️")
            Text(error)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - create_file · Schöpfung

struct CreateFileArgs: Decodable {
    var path: String = ""
    var content: String = ""
    var overwrite: Bool = false

    enum CodingKeys: String, CodingKey { case path, content, overwrite }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        overwrite = (try? c.decode(Bool.self, forKey: .overwrite)) ?? false
    }
}

struct WriteFileResult: Decodable {
    var ok: Bool?
    var error: String?

    enum CodingKeys: String, CodingKey { case ok, error }
}

struct CreateFileView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    private var accent: Color { palette.accentColor }
    private var aura: Color { palette.complementaryColor }

    private var args: CreateFileArgs? {
        guard let d = chip.args.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CreateFileArgs.self, from: d)
    }

    private var result: WriteFileResult? {
        guard let d = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WriteFileResult.self, from: d)
    }

    private var path: String { args?.path ?? "" }
    private var lang: String { sourceLanguage(for: path) }
    private var text: String { args?.content ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InstrumentHeader(glyph: "✦", title: "Schöpfung",
                             subtitle: (path as NSString).lastPathComponent,
                             accent: accent, aura: aura,
                             trailing: chip.done ? (text.isEmpty ? nil : humanBytes(text.utf8.count)) : nil)

            if let error = result?.error, !error.isEmpty {
                errorCard(error)
            } else {
                if !path.isEmpty {
                    FileLinkButton(path: path, accent: accent)
                }
                statRow
                if !text.isEmpty {
                    contentPane
                }
            }
        }
        .modifier(MirrorSurface(accent: accent, aura: aura))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var statRow: some View {
        HStack(spacing: 5) {
            StatChip(glyph: "✧", value: lang)
            StatChip(glyph: "☰", value: humanBytes(text.utf8.count))
            if chip.done {
                StatChip(glyph: args?.overwrite == true ? "↻" : "✦",
                         value: args?.overwrite == true ? "überschrieben" : "neu")
            }
        }
    }

    private var contentPane: some View {
        LineNumberedCodeView(code: text, language: lang,
                             maxHeight: 200,
                             background: palette.codeBackgroundColor.opacity(0.55))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 6) {
            Text("⚠️")
            Text(error)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - rename_file · Umbenennung

struct RenameFileArgs: Decodable {
    var from: String = ""
    var to: String = ""

    enum CodingKeys: String, CodingKey { case from, to }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = (try? c.decode(String.self, forKey: .from)) ?? ""
        to = (try? c.decode(String.self, forKey: .to)) ?? ""
    }
}

struct RenameFileView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    private var accent: Color { palette.complementaryColor }
    private var aura: Color { palette.accentColor }

    private var args: RenameFileArgs? {
        guard let d = chip.args.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RenameFileArgs.self, from: d)
    }

    private var result: WriteFileResult? {
        guard let d = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WriteFileResult.self, from: d)
    }

    private var from: String { args?.from ?? "" }
    private var to: String { args?.to ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InstrumentHeader(glyph: "⇄", title: "Umbenennung",
                             subtitle: (to as NSString).lastPathComponent,
                             accent: accent, aura: aura,
                             trailing: chip.done ? (result?.ok == true ? "vollzogen" : "fehlgeschlagen") : nil)

            if let error = result?.error, !error.isEmpty {
                errorCard(error)
            } else {
                HStack(spacing: 5) {
                    Text(from)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("→")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(to)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !to.isEmpty {
                    FileLinkButton(path: to, accent: accent)
                }
            }
        }
        .modifier(MirrorSurface(accent: accent, aura: aura))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 6) {
            Text("⚠️")
            Text(error)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - undo_patch · Rücknahme

struct UndoPatchArgs: Decodable {
    var undoToken: String = ""

    enum CodingKeys: String, CodingKey { case undoToken = "undo_token" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        undoToken = (try? c.decode(String.self, forKey: .undoToken)) ?? ""
    }
}

struct UndoPatchResult: Decodable {
    var ok: Bool?
    var path: String?
    var error: String?

    enum CodingKeys: String, CodingKey { case ok, path, error }
}

struct UndoPatchView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    private var accent: Color { palette.accentColor }
    private var aura: Color { palette.complementaryColor }

    private var args: UndoPatchArgs? {
        guard let d = chip.args.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UndoPatchArgs.self, from: d)
    }

    private var result: UndoPatchResult? {
        guard let d = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UndoPatchResult.self, from: d)
    }

    private var path: String { result?.path ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InstrumentHeader(glyph: "⟲", title: "Rücknahme",
                             subtitle: path.isEmpty ? "Schnitt" : (path as NSString).lastPathComponent,
                             accent: accent, aura: aura,
                             trailing: chip.done ? (result?.ok == true ? "vollzogen" : "fehlgeschlagen") : nil)

            if let error = result?.error, !error.isEmpty {
                errorCard(error)
            } else {
                if !path.isEmpty {
                    FileLinkButton(path: path, accent: accent)
                }
                if let token = args?.undoToken, !token.isEmpty {
                    Text(token)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .modifier(MirrorSurface(accent: accent, aura: aura))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 6) {
            Text("⚠️")
            Text(error)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.20), lineWidth: 0.5))
    }
}