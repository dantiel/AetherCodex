import Cocoa
import Foundation

// MARK: - File-Link-Verdrahtung · der eine Ort, der einen Link in einen Sprung übersetzt
//
// Der Orakel spricht Dateien als Markdown-Links an:
//
//     [CommitGenerator](aethercodex://open?path=AetherCodex/App/GitSidebar.swift&line=482&column=10)
//
// Diese zentrale Auflösung ersetzt die früher verstreuten Resolver (MarkdownBody,
// PythiaPanel, MnemosyneCauldron) und ist bewusst *tolerant* gegenüber den
// verschiedenen Schreibweisen, die ein Modell für Zeile/Spalte erfindet. Ein
// einziger Parser, der sie alle versteht — und ein Fuzzy-Fallback, der einen
// leicht danebengeratenen Pfad trotzdem an den richtigen Ort führt.

/// Eine aufgelöste Datei-Referenz, bereit zum Öffnen im Editor.
struct FileLink: Sendable {
    var path: String
    var line: Int?
    var column: Int?
}

/// Nutzlast für die `.openFileInEditor`-Benachrichtigung — trägt den Sprung
/// (Zeile/Spalte) mit, statt nur die nackte URL.
struct FileLinkRequest {
    let url: URL
    let line: Int?
    let column: Int?
}

enum FileLinkResolver {
    // MARK: - URL-Parsing (versatil · fängt Halluzinationen)

    /// Zerlegt eine `aethercodex://open`-URL in Pfad + Zeile + Spalte.
    /// Liefert `nil`, wenn es sich nicht um einen Datei-Link handelt.
    static func parse(_ url: URL) -> FileLink? {
        guard url.scheme == "aethercodex", url.host == "open" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        var path: String?
        var lineRaw: String?
        var columnRaw: String?

        // Kanonisch: path=/line=/column= als Query-Parameter.
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "path": path = item.value
            case "line": lineRaw = item.value
            case "column", "col": columnRaw = item.value
            default: break
            }
        }

        // Pfad darf auch in der URL-Pfadkomponente liegen: aethercodex://open/A/B.swift
        if path == nil || path!.isEmpty {
            let p = comps.path
            if !p.isEmpty && p != "/" {
                path = p.hasPrefix("/") ? String(p.dropFirst()) : p
            }
        }

        // Zeile/Spalte mit expliziter, zentraler Präzedenz:
        // Fragment (#L482C10) > Query (line=/column=) > Pfad-Suffix (:482:10).
        // Jede spätere Quelle trägt nur ein, was noch nicht gesetzt ist.
        var line: Int?
        var column: Int?

        // Fragment: #L482 bzw. #L482C10
        if let frag = comps.fragment?.uppercased(), frag.hasPrefix("L"),
           let lc = parseLineColumn(String(frag.dropFirst()), separator: "C") {
            line = lc.line
            column = lc.column
        }

        // "line=482:10" — die Spalte hängt am Zeilenwert.
        if line == nil, let lr = lineRaw, let lc = parseLineColumn(lr, separator: ":") {
            line = lc.line
            if column == nil { column = lc.column }
        }
        if column == nil, let cr = columnRaw { column = Int(cr) }

        // "path=A/B.swift:482:10" — VSCode-/git-Stil mit angehängter Zeile[:Spalte].
        if line == nil, let p = path, let m = trailingLocationMatch(p) {
            path = m.path
            line = m.line
            if column == nil { column = m.column }
        }

        guard let rawPath = path?.trimmingCharacters(in: .whitespaces), !rawPath.isEmpty else { return nil }
        return FileLink(path: rawPath, line: line, column: column)
    }

    /// Zerlegt "482", "482:10" oder "482C10" in Zeile + optionale Spalte —
    /// die gemeinsame Form der drei tolerant-parse-Schichten (Fragment-`C`,
    /// Query-Doppelpunkt und Pfad-Suffix-Zahlen).
    private static func parseLineColumn(_ text: String, separator: Character) -> (line: Int, column: Int?)? {
        let parts = text.split(separator: separator, maxSplits: 1)
        guard let line = Int(parts.first ?? "") else { return nil }
        var column: Int?
        if parts.count > 1, let c = Int(parts[1]) { column = c }
        return (line, column)
    }

    /// Erkennt ein angehängtes `:Zeile[:Spalte]` am Pfadende — ohne einen
    /// gewöhnlichen Doppelpunkt im Dateinamen zu treffen.
    private static func trailingLocationMatch(_ path: String) -> (path: String, line: Int, column: Int?)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.*?):(\d+)(?::(\d+))?$"#) else { return nil }
        let ns = path as NSString
        guard let m = regex.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 3 else { return nil }
        let p = ns.substring(with: m.range(at: 1))
        guard !p.isEmpty, let line = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        var column: Int?
        if m.numberOfRanges >= 4, m.range(at: 3).location != NSNotFound {
            column = Int(ns.substring(with: m.range(at: 3)))
        }
        return (p, line, column)
    }

    // MARK: - Einstiegspunkte

    /// Wird aus `OpenURLAction` (MarkdownBody, PythiaPanel) aufgerufen.
    /// Liefert `true`, wenn die URL als Datei-Link behandelt wurde.
    static func open(_ url: URL) -> Bool {
        guard let link = parse(url) else { return false }
        let resolved = resolvePath(link.path)
        post(resolved, line: link.line, column: link.column)
        return true
    }

    /// Wird aus rohen Pfad-Strings aufgerufen (Mnemosyne-Karten, Projekt-Settings).
    static func open(_ link: String, line: Int? = nil, column: Int? = nil) {
        let resolved = resolvePath(link)
        post(resolved, line: line, column: column)
    }

    private static func post(_ path: String, line: Int?, column: Int?) {
        let request = FileLinkRequest(url: URL(fileURLWithPath: path), line: line, column: column)
        NotificationCenter.default.post(name: .openFileInEditor, object: request)
    }

    // MARK: - Pfad-Auflösung

    /// Tilde-Erweiterung, absolute Pfade, projektrelative Pfade — und wenn der
    /// gemeldete Pfad nicht existiert, ein Fuzzy-Basename-Match gegen den
    /// Projektbaum (der eigentliche Halluzinations-Fänger).
    static func resolvePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let candidate: String
        if (expanded as NSString).isAbsolutePath {
            candidate = expanded
        } else {
            let root = RubyBridge.shared.projectRoot
            candidate = root.isEmpty ? expanded : (root as NSString).appendingPathComponent(expanded)
        }
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        if let fuzzy = fuzzyResolve(raw) ?? fuzzyResolve(expanded) {
            return fuzzy
        }
        return candidate
    }

    /// Findet eine Datei allein über ihren Basenamen (oder Pfad-Suffix), sofern
    /// die Zuordnung im Projekt eindeutig ist.
    private static func fuzzyResolve(_ raw: String) -> String? {
        let base = (raw as NSString).lastPathComponent
        let root = RubyBridge.shared.projectRoot
        guard !root.isEmpty, !base.isEmpty, base != "/" else { return nil }

        let files = indexedFiles(root)
        let nameMatches = files.filter { $0.fileName == base }
        if nameMatches.count == 1 { return nameMatches[0].url.path }

        let suffixMatches = files.filter { $0.relativePath == raw || $0.relativePath.hasSuffix(raw) }
        if suffixMatches.count == 1 { return suffixMatches[0].url.path }
        return nil
    }

    /// Einmalige, projektweit gecachte Datei-Indexierung — nur nötig, wenn der
    /// exakte Pfad nicht existiert (der seltene Halluzinations-Fall).
    private static var _fileIndexCache: (root: String, files: [IndexedFile])?
    private static func indexedFiles(_ root: String) -> [IndexedFile] {
        if let cache = _fileIndexCache, cache.root == root { return cache.files }
        let files = GoToFileEngine.enumerate(root: URL(fileURLWithPath: root))
        _fileIndexCache = (root, files)
        return files
    }
}