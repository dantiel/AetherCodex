import AppKit

/// Self-contained demo syntax highlighter — proves TextKit 2 carries real
/// attributed color attributes. Not the production SyntaxEngine; intentionally
/// minimal so the experiment isolates the scroll-edge mechanism.
enum DemoHighlighter {
    static var font: NSFont { NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) }

    static var keywordColor: NSColor { .systemPurple }
    static var stringColor: NSColor { .systemRed }
    static var commentColor: NSColor { .systemGreen }
    static var numberColor: NSColor { .systemOrange }
    static var typeColor: NSColor { .systemTeal }

    private static let keywordPattern = #"\b(import|struct|class|enum|func|var|let|if|else|for|while|return|guard|switch|case|in|try|throw|catch|async|await|extension|protocol|init|deinit|self|super|override|private|public|internal|static|final|where|typealias)\b"#

    static func highlight(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        result.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)

        // Order matters: comments/strings swallow inner tokens first.
        apply(pattern: #"//[^\n]*"#, color: commentColor, text: text, to: result)
        apply(pattern: #""(?:[^"\\]|\\.)*""#, color: stringColor, text: text, to: result)
        apply(pattern: #"\b\d+(?:\.\d+)?\b"#, color: numberColor, text: text, to: result)
        apply(pattern: keywordPattern, color: keywordColor, text: text, to: result)
        apply(pattern: #"\b[A-Z][A-Za-z0-9]*\b"#, color: typeColor, text: text, to: result)
        return result
    }

    private static func apply(pattern: String, color: NSColor, text: String, to result: NSMutableAttributedString) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

/// A large mixed document: Swift code, a couple of very long lines (to exercise
/// horizontal scroll for the trailing edge), and prose blocks. Scrolling this
/// under the top/leading/trailing safeAreaBars is what exposes the native fade.
enum DemoContent {
    static var text: String {
        var lines: [String] = []
        for i in 0..<80 {
            let n = i + 1
            lines.append("// Block \(n) — generated demo content")
            lines.append("import Foundation")
            lines.append("")
            lines.append("struct Sample\(n) {")
            lines.append("    var count: Int = \(n * 7)")
            lines.append("    let name: String = \"sample_\(n)\"")
            lines.append("")
            lines.append("    func compute(_ input: Double) -> Double {")
            lines.append("        if input < 0 { return 0 }")
            lines.append("        var total = input * 3.14")
            lines.append("        for j in 0..<count {")
            lines.append("            total += Double(j) * 0.5")
            lines.append("        }")
            lines.append("        return total")
            lines.append("    }")
            lines.append("}")
            lines.append("")
            // A very long line — exercises horizontal scroll / trailing edge.
            lines.append("// LONG: \(String(repeating: "tokens, ", count: 90)) the quick brown fox jumps over the lazy dog 12345 \"string\" \(n)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}