import Cocoa
import SwiftUI

// MARK: - Datei-Spiegel · die Sicht des Orakels

/// `file_overview` liefert nicht nur "reading… json", sondern den *Spiegel* eines
/// Kontexts: welche Struktur das Orakel in einer Datei erkennt (Behälter, Glieder,
/// Importe/Exporte), welche Fäden (Tags) und Nachbarn (verlinkte Dateien) sich um
/// sie ranken und welche Echos aus dem Kessel an ihr haften. Diese View zeigt genau
/// das — als ein stilles Gewässer, in dem die Zeichen der Datei schwimmen.

enum FileOverviewTool {
    static func isFileOverview(_ name: String) -> Bool { name == "file_overview" }
}

// MARK: - Modell

struct FileOverviewResult: Decodable {
    var notesCount: Int = 0
    var notesPreview: [FileOverviewNote] = []
    var fileInfo: FileOverviewInfo?
    var summary: FileOverviewSummary?
    var symbolicOverview: String = ""
    var tagCloud: String = ""
    var fileCloud: String = ""
    var hermeticOverview: [String] = []
    var executionTime: Double = 0

    enum CodingKeys: String, CodingKey {
        case notesCount = "notes_count"
        case notesPreview = "notes_preview"
        case fileInfo = "file_info"
        case summary = "structural_summary"
        case symbolicOverview = "symbolic_overview"
        case tagCloud = "tag_cloud"
        case fileCloud = "file_cloud"
        case hermeticOverview = "hermetic_overview"
        case executionTime = "execution_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notesCount = (try? c.decode(Int.self, forKey: .notesCount)) ?? 0
        notesPreview = (try? c.decode([FileOverviewNote].self, forKey: .notesPreview)) ?? []
        fileInfo = try? c.decode(FileOverviewInfo.self, forKey: .fileInfo)
        summary = try? c.decode(FileOverviewSummary.self, forKey: .summary)
        symbolicOverview = (try? c.decode(String.self, forKey: .symbolicOverview)) ?? ""
        tagCloud = (try? c.decode(String.self, forKey: .tagCloud)) ?? ""
        fileCloud = (try? c.decode(String.self, forKey: .fileCloud)) ?? ""
        // hermetic_overview ist ein Array von Resonanz-Zeilen — oder ein
        // Fehler-Hash. Bei Fehler bleibt die Resonanz einfach still.
        hermeticOverview = (try? c.decode([String].self, forKey: .hermeticOverview)) ?? []
        executionTime = (try? c.decode(Double.self, forKey: .executionTime)) ?? 0
    }
}

struct FileOverviewNote: Decodable, Identifiable {
    var id: Int = 0
    var tags: [String] = []
    var excerpt: String = ""
    var links: [String] = []

    enum CodingKeys: String, CodingKey { case id, tags, excerpt, links }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        tags = Self.asStringArray(c, .tags)
        excerpt = (try? c.decode(String.self, forKey: .excerpt)) ?? ""
        links = Self.asStringArray(c, .links)
    }

    private static func asStringArray(_ c: KeyedDecodingContainer<CodingKeys>,
                                      _ key: CodingKeys) -> [String] {
        if let arr = try? c.decode([String].self, forKey: key) { return arr }
        if let str = try? c.decode(String.self, forKey: key) {
            return str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

struct FileOverviewInfo: Decodable {
    var lines: Int = 0
    var size: Int = 0
    var lastModified: String = ""
    var path: String = ""

    enum CodingKeys: String, CodingKey { case lines, size, lastModified = "last_modified", path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = (try? c.decode(Int.self, forKey: .lines)) ?? 0
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        lastModified = (try? c.decode(String.self, forKey: .lastModified)) ?? ""
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
    }
}

struct FileOverviewSummary: Decodable {
    var language: String = ""
    var containers: Int = 0
    var members: Int = 0
    var imports: Int = 0
    var exports: Int = 0
    var totalSymbols: Int = 0

    enum CodingKeys: String, CodingKey {
        case language, containers, members, imports, exports, totalSymbols = "total_symbols"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? c.decode(String.self, forKey: .language)) ?? ""
        containers = (try? c.decode(Int.self, forKey: .containers)) ?? 0
        members = (try? c.decode(Int.self, forKey: .members)) ?? 0
        imports = (try? c.decode(Int.self, forKey: .imports)) ?? 0
        exports = (try? c.decode(Int.self, forKey: .exports)) ?? 0
        totalSymbols = (try? c.decode(Int.self, forKey: .totalSymbols)) ?? 0
    }
}

// MARK: - Spiegel

struct FileOverviewView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette
    @State private var breathe = false

    private var result: FileOverviewResult? {
        guard let data = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileOverviewResult.self, from: data)
    }

    private var accent: Color { palette.accentColor }
    private var aura: Color { palette.complementaryColor }
    private var shine: Color { palette.shineColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            if let result {
                if let info = result.fileInfo {
                    infoRow(info)
                }
                if let summary = result.summary {
                    summaryRow(summary)
                }
                if !result.symbolicOverview.isEmpty {
                    symbolicSection(result.symbolicOverview)
                }
                if !result.tagCloud.isEmpty {
                    cloudSection("Fäden", text: result.tagCloud, tint: aura)
                }
                if !result.fileCloud.isEmpty {
                    fileCloudSection(result.fileCloud)
                }
                if !result.notesPreview.isEmpty {
                    echoesSection(result.notesPreview)
                }
                if !result.hermeticOverview.isEmpty {
                    resonanceSection(result.hermeticOverview)
                }
            } else {
                fallbackCard
            }
        }
        .padding(8)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(chip.done ? 0.12 : 0.28), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(LinearGradient(colors: [accent.opacity(0.9), aura.opacity(0.5), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2.5)
                .padding(.vertical, 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: [accent.opacity(0.13), aura.opacity(0.07), Color.clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 7) {
            orb
            VStack(alignment: .leading, spacing: 1) {
                Text("Datei-Spiegel")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("die Sicht des Orakels")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let result, result.executionTime > 0 {
                Text(String(format: "%.0f ms", result.executionTime * 1000))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.05), in: Capsule())
            }
        }
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.55), aura.opacity(0.10), .clear],
                                     center: .center, startRadius: 1, endRadius: 16))
                .frame(width: 30, height: 30)
                .scaleEffect(breathe ? 1.14 : 0.96)
                .blur(radius: 1)
                .opacity(breathe ? 0.9 : 0.55)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [accent.opacity(0.7), aura.opacity(0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                )
            Text("🌘")
                .font(.system(size: 12))
        }
        .frame(width: 30, height: 30)
    }

    // MARK: Datei-Info

    private func infoRow(_ info: FileOverviewInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !info.path.isEmpty {
                FileLinkButton(path: info.path, accent: accent)
            }
            HStack(spacing: 5) {
                StatChip(glyph: "☰", value: "\(info.lines) Zeilen")
                StatChip(glyph: "◧", value: humanSize(info.size))
                if let lang = result?.summary?.language, !lang.isEmpty {
                    StatChip(glyph: "✧", value: lang)
                }
            }
            if !info.lastModified.isEmpty {
                Text(info.lastModified)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accent.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func humanSize(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
        return "\(bytes) B"
    }

    // MARK: Bau (Struktur)

    private func summaryRow(_ s: FileOverviewSummary) -> some View {
        HStack(spacing: 5) {
            StatChip(glyph: "▣", value: "\(s.containers) Behälter")
            StatChip(glyph: "◈", value: "\(s.members) Glieder")
            StatChip(glyph: "↥", value: "\(s.imports) Importe")
            StatChip(glyph: "↧", value: "\(s.exports) Exporte")
            StatChip(glyph: "✦", value: "\(s.totalSymbols) Symbole")
        }
    }

    // MARK: Symbolische Sicht

    private func symbolicSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("Zeichen", glyph: "≋")
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(Array(symbolicRows(text).enumerated()), id: \.offset) { row in
                        symbolicLine(row.element)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(maxHeight: 150)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .background(shine.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(shine.opacity(0.18), lineWidth: 0.5)
            )
        }
    }

    private enum SymbolTint { case symbol, imp, exp }

    private func symbolicRows(_ text: String) -> [(String, SymbolTint)] {
        text.components(separatedBy: "\n").map { raw in
            let body = raw.trimmingCharacters(in: .whitespaces)
            if body.contains(" import ") || body.hasPrefix("import ") { return (raw, .imp) }
            if body.contains(" export ") || body.hasPrefix("export ") { return (raw, .exp) }
            return (raw, .symbol)
        }.filter { !$0.0.isEmpty }
    }

    private func symbolicLine(_ row: (String, SymbolTint)) -> some View {
        let color: Color = {
            switch row.1 {
            case .imp:  return shine
            case .exp:  return Color.mint
            case .symbol: return .secondary
            }
        }()
        return Text(row.0)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    // MARK: Fäden (Tags)

    private struct CloudItem: Identifiable {
        let id = UUID()
        let key: String
        let count: Int
    }

    private func cloudSection(_ label: String, text: String, tint: Color) -> some View {
        let items = cloudItems(text)
        let maxCount = items.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 3) {
            sectionLabel(label, glyph: "❀")
            FlowLayout(spacing: 4) {
                ForEach(items) { item in
                    Text(item.key)
                        .font(.system(size: 8 + 2.5 * CGFloat(item.count) / CGFloat(maxCount),
                                      weight: .medium, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.55 + 0.45 * CGFloat(item.count) / CGFloat(maxCount)))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
                }
            }
        }
    }

    private func cloudItems(_ text: String) -> [CloudItem] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return CloudItem(key: String(parts[0]), count: n)
        }
    }

    // MARK: Nachbarn (verlinkte Dateien)

    private func fileCloudSection(_ text: String) -> some View {
        let items = cloudItems(text)
        return VStack(alignment: .leading, spacing: 3) {
            sectionLabel("Nachbarn", glyph: "⌘")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        FileLinkButton(path: item.key, accent: accent)
                        Spacer(minLength: 0)
                        Text("×\(item.count)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
            }
        }
    }

    // MARK: Echos (verwandte Notizen)

    private func echoesSection(_ notes: [FileOverviewNote]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("Echos", glyph: "◌")
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    if !note.excerpt.isEmpty {
                        Text(renderInline(note.excerpt))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    if !note.tags.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(note.tags.prefix(4), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(aura.opacity(0.10), in: Capsule())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Resonanz

    private func resonanceSection(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("Resonanz", glyph: "≈")
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private func sectionLabel(_ text: String, glyph: String) -> some View {
        HStack(spacing: 4) {
            Text(glyph).font(.system(size: 8))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var fallbackCard: some View {
        HStack(spacing: 6) {
            Text("🌘")
            Text("Kein Spiegel erhebt sich.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Stat-Chip

struct StatChip: View {
    let glyph: String
    let value: String
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            Text(glyph).font(.system(size: 8))
            Text(value)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(palette.accentColor.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(palette.accentColor.opacity(0.14), lineWidth: 0.5))
    }
}

// MARK: - Fließ-Layout (für die Fäden-Wolke)

/// Minimales umbrechendes Layout — kein vollwertiger HTML-Box-Renderer, nur
/// genug, damit Fäden (Tags) natürlich in Zeilen fließen statt zu clippen.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return CGSize(width: width, height: layoutHeight(width: width, subviews: subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func layoutHeight(width: CGFloat, subviews: Subviews) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}