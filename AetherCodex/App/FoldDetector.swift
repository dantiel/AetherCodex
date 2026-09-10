import Foundation

// MARK: - Fold Region

struct FoldRegion: Equatable, Hashable {
    let startLine: Int
    let endLine: Int
    let openToken: String
    let openCharIndex: Int
    let closeCharIndex: Int

    var lineCount: Int { endLine - startLine + 1 }
    var isFoldable: Bool { lineCount > 1 }

    func hash(into hasher: inout Hasher) {
        hasher.combine(startLine)
        hasher.combine(endLine)
        hasher.combine(openToken)
    }
}

// MARK: - Fold Detector

enum FoldDetector {

    private static let bracePairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]
    private static let closers: Set<Character> = ["}", ")", "]"]

    private static let blockKeywords: Set<String> = [
        "if", "for", "while", "def", "class", "module", "do", "begin",
        "switch", "case", "func", "struct", "enum", "protocol", "extension",
        "guard", "repeat", "catch", "else", "elsif", "when", "unless",
        "until", "rescue", "ensure", "finally",
    ]

    // MARK: - Public

    static func detect(in text: String) -> [FoldRegion] {
        var regions = detectBraces(in: text)
        if regions.count < 3 {
            regions.append(contentsOf: detectIndentationBlocks(in: text))
        }
        var seen: [Int: FoldRegion] = [:]
        for r in regions where r.isFoldable {
            if let existing = seen[r.startLine] {
                if r.endLine > existing.endLine { seen[r.startLine] = r }
            } else {
                seen[r.startLine] = r
            }
        }
        return Array(seen.values).sorted { $0.startLine < $1.startLine }
    }

    // MARK: - Brace Matching

    private static func detectBraces(in text: String) -> [FoldRegion] {
        var regions: [FoldRegion] = []
        var stack: [(char: Character, charIndex: Int, line: Int)] = []
        var line = 0
        let chars = Array(text)

        for (i, ch) in chars.enumerated() {
            if ch == "\n" { line += 1 }

            if bracePairs[ch] != nil {
                stack.append((ch, i, line))
            } else if closers.contains(ch), let top = stack.last {
                let expected = bracePairs[top.char]!
                if ch == expected {
                    stack.removeLast()
                    if top.line < line {
                        regions.append(FoldRegion(
                            startLine: top.line, endLine: line,
                            openToken: String(top.char),
                            openCharIndex: top.charIndex, closeCharIndex: i))
                    }
                } else {
                    stack.removeAll()
                }
            }
        }
        return regions
    }

    // MARK: - Indentation-based

    private static func detectIndentationBlocks(in text: String) -> [FoldRegion] {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        var regions: [FoldRegion] = []
        var blockStack: [(indent: Int, startLine: Int, keyword: String)] = []

        for (i, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            let firstWord = trimmed.components(separatedBy: .whitespaces).first

            while let top = blockStack.last, indent <= top.indent {
                if i - top.startLine > 1 {
                    let nsText = text as NSString
                    let s = charIdx(forLine: top.startLine, in: nsText)
                    let e = charIdx(forLine: i - 1, in: nsText)
                    regions.append(FoldRegion(startLine: top.startLine, endLine: i - 1,
                        openToken: top.keyword, openCharIndex: s, closeCharIndex: e))
                }
                blockStack.removeLast()
            }

            if let kw = firstWord, blockKeywords.contains(kw) {
                blockStack.append((indent, i, kw))
            }
        }

        for top in blockStack where lines.count - 1 - top.startLine > 1 {
            let nsText = text as NSString
            let s = charIdx(forLine: top.startLine, in: nsText)
            regions.append(FoldRegion(startLine: top.startLine, endLine: lines.count - 1,
                openToken: top.keyword, openCharIndex: s, closeCharIndex: nsText.length))
        }
        return regions
    }

    private static func charIdx(forLine line: Int, in nsText: NSString) -> Int {
        var cur = 0, pos = 0
        while cur < line && pos < nsText.length {
            let r = nsText.safeLineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(r); cur += 1
        }
        return min(pos, nsText.length)
    }
}
