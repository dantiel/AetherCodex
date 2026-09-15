import SwiftUI

// MARK: - Line-numbered code mirror

/// Themed code pane with a fixed line-number gutter — the Pythia echo of the
/// editor's `LineNumberRulerView`. Numbers are right-aligned and muted, a thin
/// separator divides gutter from source, and the gutter stays pinned while long
/// lines scroll horizontally. Gutter and source share one font/lineSpacing so
/// numbers and tokens never drift apart, whatever the theme or file length.
struct LineNumberedCodeView: View {
    let code: String
    let language: String
    var startLine: Int = 1
    var font: Font = .system(size: 10, design: .monospaced)
    var fontSize: CGFloat = 10
    var lineSpacing: CGFloat = 0
    var maxHeight: CGFloat = 240
    var background: Color? = nil
    var border: Color? = nil
    var fallback: NSColor? = nil
    var showsLineNumbers: Bool = true

    @Environment(\.pythiaPalette) private var palette

    // MARK: - Metrics

    private var lineCount: Int { code.components(separatedBy: "\n").count }
    private var lastLine: Int { startLine + lineCount - 1 }
    private var digits: Int { max(String(max(startLine, lastLine)).count, 1) }
    /// SF Mono advance ≈ 0.6 × point size.
    private var charWidth: CGFloat { fontSize * 0.6 }
    private var numberWidth: CGFloat { CGFloat(digits) * charWidth }

    private let leftPad: CGFloat = 6
    private let rightGap: CGFloat = 6
    private let vPad: CGFloat = 8

    private var gutterText: String {
        (startLine..<(startLine + lineCount)).map(String.init).joined(separator: "\n")
    }

    // MARK: - Colors

    private var codeBackground: Color { background ?? palette.codeBackgroundColor }
    private var borderColor: Color { border ?? palette.shineColor.opacity(0.22) }
    private var numberColor: Color {
        Color(nsColor: palette.codeForeground.mixed(with: palette.background, amount: 0.5))
    }
    private var gutterBackground: Color { palette.codeForegroundColor.opacity(0.055) }
    private var separatorColor: Color { palette.shineColor.opacity(0.2) }

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                if showsLineNumbers { gutter }
                codePane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background(codeBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var gutter: some View {
        Text(gutterText)
            .font(font)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(numberColor)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.top, vPad)
            .padding(.bottom, vPad)
            .padding(.leading, leftPad)
            .padding(.trailing, rightGap)
            .background(gutterBackground)
            .overlay(alignment: .trailing) {
                Rectangle().fill(separatorColor).frame(width: 0.5)
            }
    }

    private var codePane: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(highlightCode(code, language: language, fallback: fallback))
                .font(font)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, vPad)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
