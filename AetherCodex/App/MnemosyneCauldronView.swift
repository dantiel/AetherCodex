import Cocoa
import SwiftUI

// MARK: - Mnemosyne · der Kessel der Erinnerung

/// Mnemosyne hütet den Schlaf der Erinnerung — doch jedes ihrer Auftreten in
/// hermetischer Freiheit schenkt ein Lächeln. Statt eines rohen JSON-Fragments
/// erscheinen ihre Notizen als ein *Kessel*: eine schimmernde Kammer, in der jede
/// Erinnerung als Echo aufsteigt — Inhalt, Stärke, Tags und Herkunft als ein
/// einziges, stilles Gefäß.
///
/// Diese View verarbeitet die strukturierten Ergebnisse der Mnemosyne-Instrumente
/// (`recall_notes`, `recall_history`, `get_note`, `remember`, `remove_note`,
/// `metempsychosis`, `aegis`) und lässt sie durch die aktive Kammer-Palette atmen.

// MARK: - Werkzeug-Erkennung

enum MnemosyneTool {
    static let names: Set<String> = [
        "remember", "remove_note", "recall_notes", "recall_history",
        "get_note", "metempsychosis", "aegis"
    ]

    static func isMnemosyne(_ name: String) -> Bool {
        names.contains(name)
    }
}

// MARK: - Modell

/// Eine einzelne Erinnerung, wie sie Mnemosyne ausliefert.
struct MnemosyneNote: Decodable, Identifiable {
    let id: Int
    let content: String
    var tags: String = ""
    var links: String = ""
    var createdAt: String = ""
    var score: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, content, tags, links, createdAt = "created_at", score
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        tags = (try? c.decode(String.self, forKey: .tags)) ?? ""
        links = (try? c.decode(String.self, forKey: .links)) ?? ""
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        if let i = try? c.decode(Int.self, forKey: .score) {
            score = Double(i)
        } else if let d = try? c.decode(Double.self, forKey: .score) {
            score = d
        }
    }

    var tagList: [String] { splitList(tags) }
    var linkList: [String] { splitList(links) }

    private func splitList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Hülle für die Rückgabe von `recall_notes` / `aegis` / `metempsychosis`:
/// `{ "notes": [...] }` bzw. `{ "aegis_notes": [...] }` plus Laufzeit.
struct MnemosyneMemory: Decodable {
    var notes: [MnemosyneNote] = []
    var executionTime: Double = 0

    enum CodingKeys: String, CodingKey {
        case notes, aegisNotes = "aegis_notes", executionTime = "execution_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = (try? c.decode([MnemosyneNote].self, forKey: .notes))
            ?? (try? c.decode([MnemosyneNote].self, forKey: .aegisNotes))
            ?? []
        executionTime = (try? c.decode(Double.self, forKey: .executionTime)) ?? 0
    }
}

// MARK: - Kessel

struct MnemosyneCauldronView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette
    @State private var breathe = false

    private var memory: MnemosyneMemory? {
        guard let data = chip.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MnemosyneMemory.self, from: data)
    }

    private var verb: String {
        switch chip.name {
        case "remember":            return "senkte ein Echo in die Tiefe"
        case "remove_note":         return "ließ ein Echo im Nebel zergehen"
        case "metempsychosis":      return "trägt ein Echo zwischen Gewässern"
        case "aegis":               return "entfaltet den aktiven Æther"
        default:                    return "hebt ein Echo aus der Tiefe"
        }
    }

    private var glyph: String {
        switch chip.name {
        case "remember":            return "🪷"
        case "remove_note":         return "🌫️"
        case "metempsychosis":      return "🦋"
        case "aegis":               return "🛡️"
        default:                    return "🔮"
        }
    }

    private var aura: Color { palette.complementaryColor }
    private var accent: Color { palette.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            if let memory, !memory.notes.isEmpty {
                ForEach(memory.notes) { note in
                    NoteCard(note: note, aura: aura, accent: accent)
                }
            } else if chip.name == "remember" {
                wovenCard
            } else if chip.name == "remove_note" {
                forgottenCard
            } else {
                emptyCard
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
                .fill(
                    LinearGradient(colors: [accent.opacity(0.9), aura.opacity(0.5), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 2.5)
                .padding(.vertical, 8)
        }
        .overlay(alignment: .topTrailing) {
            surfaceLilies
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Klarwasser-Grund mit Nebelschleier: die Tiefe bleibt unten, an der
    /// Oberfläche spiegelt sich nur ein stilles, schimmerndes Gewässer.
    private var background: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: [
                        aura.opacity(0.16),
                        accent.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.07), .clear],
                            center: .topLeading, startRadius: 2, endRadius: 90
                        )
                    )
                    .blur(radius: 2)
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Seerosen/Lotos, die sanft auf der Oberfläche des Gewässers treiben.
    private var surfaceLilies: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { i in
                Text("🪷")
                    .font(.system(size: 10 + CGFloat(i)))
                    .opacity(breathe ? 0.55 : 0.28)
                    .offset(y: breathe ? -1 : 1)
            }
        }
        .padding(.top, 3)
        .padding(.trailing, 7)
        .allowsHitTesting(false)
    }

    // MARK: Kopf — der Kessel

    private var header: some View {
        HStack(spacing: 7) {
            cauldronOrb
            VStack(alignment: .leading, spacing: 1) {
                Text("Mnemosyne")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(verb)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let memory, memory.executionTime > 0 {
                Text(String(format: "%.0f ms", memory.executionTime * 1000))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.05), in: Capsule())
            }
        }
    }

    private var cauldronOrb: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.55), aura.opacity(0.10), .clear],
                        center: .center, startRadius: 1, endRadius: 16
                    )
                )
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

            Text(glyph)
                .font(.system(size: 12))
        }
        .frame(width: 30, height: 30)
    }

    // MARK: Erinnerungskarten

    private var wovenCard: some View {
        let content = argContent()
        let tags = argTags()
        let links = argLinks()
        let id = argID()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Text("🪷")
                    .font(.system(size: 10))
                Text(content.isEmpty ? "In die Tiefe gesenkt." : content)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let id {
                Text("#\(id)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
                        }
                    }
                }
            }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(links, id: \.self) { link in
                        FileLinkButton(path: link, accent: accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var forgottenCard: some View {
        HStack(spacing: 6) {
            Text("🌫️")
            Text("Echo \(argID() ?? 0) im Nebel zergangen.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyCard: some View {
        HStack(spacing: 6) {
            Text("🌌")
            Text("Die Tiefe schweigt.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func argDict() -> [String: Any]? {
        guard let data = chip.args.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func argContent() -> String {
        argDict()?["content"] as? String ?? ""
    }

    private func argTags() -> [String] {
        guard let dict = argDict() else { return [] }
        if let arr = dict["tags"] as? [String] { return arr.filter { !$0.isEmpty } }
        if let s = dict["tags"] as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func argLinks() -> [String] {
        guard let dict = argDict() else { return [] }
        if let arr = dict["links"] as? [String] { return arr.filter { !$0.isEmpty } }
        if let s = dict["links"] as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func argID() -> Int? {
        guard let dict = argDict() else { return nil }
        if let i = dict["id"] as? Int { return i }
        if let s = dict["id"] as? String { return Int(s) }
        return nil
    }
}

// MARK: - Einzelnes Echo

private struct NoteCard: View {
    let note: MnemosyneNote
    let aura: Color
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🪷")
                    .font(.system(size: 10))
                    .opacity(0.7)
                echoDots
                Spacer(minLength: 0)
                if note.id != 0 {
                    Text("#\(note.id)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }

            MarkdownBody(text: note.content)
                .environment(\.markdownBodyScale, noteMarkdownScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // Unterhalb dieser Linie schlummert die Tiefe — unaufdringlich,
            // ohne an der Oberfläche zu verweilen.
            if !note.tagList.isEmpty || !note.linkList.isEmpty || !note.createdAt.isEmpty {
                Rectangle()
                    .fill(LinearGradient(colors: [accent.opacity(0.22), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 0.5)
                    .opacity(0.6)
            }
            if !note.tagList.isEmpty {
                tagRow
            }
            if !note.linkList.isEmpty {
                linkRow
            }
            if !note.createdAt.isEmpty {
                Text(note.createdAt)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accent.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var echoDots: some View {
        let n = min(max(Int(note.score.rounded()), 1), 5)
        return HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < n ? aura.opacity(0.85) : Color.secondary.opacity(0.14))
                    .frame(width: 4, height: 4)
            }
        }
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(note.tagList, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
                }
            }
        }
    }

    private var linkRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(note.linkList, id: \.self) { link in
                FileLinkButton(path: link, accent: accent)
            }
        }
    }
}

// MARK: - Klickbarer Datei-Link

/// Ein einzelner Herkunfts-Link einer Erinnerung. Ein Klick öffnet die verlinkte
/// Datei im Editor — die Erinnerung führt zurück an den Ort, aus dem sie stieg.
struct FileLinkButton: View {
    let path: String
    let accent: Color
    @State private var hovering = false

    /// Strips the "not found" strikethrough markers Mnemosyne prepends so the
    /// filetype icon resolves against the real path, not the decoration.
    private var cleanPath: String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("~~") && p.hasSuffix("~~") {
            p = String(p.dropFirst(2).dropLast(2))
        }
        if let r = p.range(of: " (path not found)") {
            p = String(p[..<r.lowerBound])
        }
        return p
    }

    var body: some View {
        Button {
            FileLinkResolver.open(cleanPath)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: FileIcon.symbol(for: URL(fileURLWithPath: cleanPath)))
                    .font(.system(size: 7.5))
                Text(path)
                    .font(.system(size: 8.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(hovering ? accent : accent.opacity(0.70))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(hovering ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}