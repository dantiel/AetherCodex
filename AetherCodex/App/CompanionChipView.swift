import Cocoa
import SwiftUI

// MARK: - Gefährten-Instrumente · die Stimme statt des JSON-Fragments

/// Die Begleiter-Instrumente (`*_say`, `*_suggest`, `*_commit`, `*_ask`) tragen
/// keine rohen Parameter-Blöcke, sondern *Stimmen*. Ein `corax_commit` ist kein
/// JSON-Dump — es ist Codex Corax, der eine Erkenntnis im Gedächtnis verankert.
/// Diese View übersetzt das strukturierte Argument in die Geste des Begleiters.

enum CompanionTool {
    enum Kind: String, CaseIterable {
        case commit, say, suggest, ask
    }

    static func kind(_ name: String) -> Kind? {
        Kind.allCases.first { name.hasSuffix("_\($0.rawValue)") }
    }

    static func isCompanion(_ name: String) -> Bool {
        kind(name) != nil
    }

    /// Der Begleiter-Präfix eines Instrument-Namens (`corax_commit` → `corax`).
    static func companionID(for name: String) -> String? {
        guard let k = kind(name) else { return nil }
        let suffix = "_\(k.rawValue)"
        guard name.hasSuffix(suffix) else { return nil }
        return String(name.dropLast(suffix.count))
    }

    static func companion(for name: String) -> Companion? {
        guard let id = companionID(for: name) else { return nil }
        return pythiaCompanions.first { $0.id == id }
    }

    /// Die einzeilige Minified-Zeile: statt `🗣️ Gefährte corax_commit` spricht
    /// der Begleiter selbst — Glyph + die Kernaussage seiner Geste.
    static func minifiedLine(name: String, args: String) -> String? {
        guard let kind = kind(name), let companion = companion(for: name) else { return nil }
        guard let data = args.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "\(companion.glyph) \(companion.displayName)"
        }
        let g = companion.glyph
        switch kind {
        case .say:
            if let m = dict["message"] as? String, !m.isEmpty { return "\(g) \(m)" }
        case .suggest:
            if let p = dict["prompt"] as? String, !p.isEmpty { return "\(g) \(p)" }
        case .commit:
            if let s = dict["summary"] as? String, !s.isEmpty { return "\(g) \(s)" }
            if let f = dict["facet_note"] as? String, !f.isEmpty { return "\(g) \(f)" }
        case .ask:
            if let q = dict["question"] as? String, !q.isEmpty { return "\(g) fragt: \(q)" }
        }
        return "\(g) \(companion.displayName)"
    }
}

// MARK: - Die Stimme

struct CompanionChipView: View {
    let chip: ToolChip
    @Environment(\.pythiaPalette) private var palette

    private var sem: InstrumentaSemantics { InstrumentaSemantics.forTool(chip.name) }
    private var companion: Companion? { CompanionTool.companion(for: chip.name) }
    private var kind: CompanionTool.Kind? { CompanionTool.kind(chip.name) }

    private var glyph: String { companion?.glyph ?? sem.glyph }
    private var name: String { companion?.displayName ?? chip.name }
    private var accent: Color { sem.tint }
    private var aura: Color { palette.complementaryColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            content
        }
        .padding(8)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(chip.done ? 0.14 : 0.30), lineWidth: 0.5)
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
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(glyph)
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
            Spacer(minLength: 0)
            Text(verb)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if chip.done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent.opacity(0.8))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var verb: String {
        switch kind {
        case .say:     return "spricht"
        case .suggest: return "schlägt vor"
        case .commit:  return "verankert"
        case .ask:     return "wird befragt"
        case nil:      return ""
        }
    }

    // MARK: Inhalte je Geste

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .say:     sayContent
        case .suggest: suggestContent
        case .commit:  commitContent
        case .ask:     askContent
        case nil:      EmptyView()
        }
    }

    @ViewBuilder
    private var sayContent: some View {
        let level = arg("level")
        HStack(alignment: .top, spacing: 6) {
            quoteBar
            VStack(alignment: .leading, spacing: 3) {
                Text(arg("message") ?? chip.output)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let level, !level.isEmpty {
                    Text(level == "warn" ? "⚠︎ Warnung" : "ℹ︎ Hinweis")
                        .font(.system(size: 8.5))
                        .foregroundStyle(level == "warn" ? Color.orange : accent.opacity(0.85))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(accent)
                    .padding(.top, 1)
                Text(arg("prompt") ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let t = temperamentLine {
                Text(t)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commitContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let summary = arg("summary") {
                field(label: "Identität", text: summary)
            }
            if let facet = arg("facet_note") {
                field(label: "Erkenntnis", text: facet)
            }
            if let domain = arg("domain_model") {
                field(label: "Domänen-Modell", text: domain)
            }
            if let score = scoreText {
                HStack(spacing: 5) {
                    Text("⚖︎")
                    Text("Relevanz \(score)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(accent.opacity(0.9))
                }
            }
            let tags = list("tags")
            let links = list("links")
            if !tags.isEmpty {
                FlowChips(items: tags, accent: accent)
            }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(links, id: \.self) { link in
                        FileLinkButton(path: link, accent: accent)
                    }
                }
            }
            if chip.done {
                Text("in Pythias geteiltem Gedächtnis verankert")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var askContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let question = arg("question") {
                HStack(alignment: .top, spacing: 6) {
                    Text("›")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)
                    Text(question)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let answer = answerText {
                HStack(alignment: .top, spacing: 6) {
                    quoteBar
                    Text(answer)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = outputError {
                Text("⚠︎ \(error)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quoteBar: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(accent.opacity(0.55))
            .frame(width: 2.5)
    }

    private var temperamentLine: String? {
        guard let dict = argDict() else { return nil }
        let t = dict["temperature"] as? NSNumber
        let thinking = dict["thinking"] as? String
        var parts: [String] = []
        if let t { parts.append("temp \(t.stringValue)") }
        if let thinking, !thinking.isEmpty { parts.append(thinking) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var scoreText: String? {
        guard let v = argDict()?["score"] else { return nil }
        if let i = v as? Int { return "\(i)" }
        if let d = v as? Double {
            return d == d.rounded() ? "\(Int(d))" : String(format: "%.1f", d)
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private var answerText: String? {
        guard let out = outputDict() else { return nil }
        if let say = out["say"] as? [String: Any] {
            let m = say["message"] as? String
            if let m, !m.isEmpty { return m }
        }
        return nil
    }

    private var outputError: String? {
        guard let out = outputDict() else { return nil }
        if let e = out["error"] as? String, !e.isEmpty { return e }
        return nil
    }

    // MARK: Parsing

    private func argDict() -> [String: Any]? {
        guard let data = chip.args.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func outputDict() -> [String: Any]? {
        guard let data = chip.output.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func arg(_ key: String) -> String? {
        guard let v = argDict()?[key] as? String, !v.isEmpty else { return nil }
        return v
    }

    private func list(_ key: String) -> [String] {
        guard let dict = argDict() else { return [] }
        if let arr = dict[key] as? [String] { return arr.filter { !$0.isEmpty } }
        if let s = dict[key] as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func field(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(accent.opacity(0.75))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: [aura.opacity(0.14), accent.opacity(0.08), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
    }
}

// MARK: - Tags als fließende Chips

private struct FlowChips: View {
    let items: [String]
    let accent: Color

    var body: some View {
        FlowLayout(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
            }
        }
    }
}

/// Einfaches fließendes Layout für kleine Chips — kein `Layout`-Protokoll nötig,
/// es reiht sich einfach umbrechend an.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity

        // Unbegrenzte Breite: alles in eine Zeile, echte Inhaltsbreite zurückgeben.
        guard maxWidth.isFinite else {
            var total: CGFloat = 0
            var maxH: CGFloat = 0
            for sub in subviews {
                let s = sub.sizeThatFits(.unspecified)
                total += s.width + spacing
                maxH = max(maxH, s.height)
            }
            total = max(0, total - spacing)
            return CGSize(width: total, height: maxH)
        }

        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            var s = sub.sizeThatFits(.unspecified)
            if s.width > maxWidth {
                // Überlanger Chip: auf Zeilenbreite klemmen, damit der Text kürzt.
                s = sub.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if x + s.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            var s = sub.sizeThatFits(.unspecified)
            if s.width > maxWidth {
                s = sub.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}