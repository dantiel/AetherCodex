import AppKit

/// One visual truth, two renderers — Correspondence.
///
/// The SwiftUI oracle surface (`MarkdownTableView`) and the editable AppKit
/// surface (`RichTextTable`) read their theme scopes and geometry from here, so
/// a table reads the same whether the oracle wrote it or the user typed it.
/// Both surfaces stay *native* to their host (a SwiftUI view cannot live inside
/// an editable `NSTextView` without breaking text editing) — what they share is
/// the grammar: the same padding, the same scopes, the same border.
enum MarkdownTableStyle {
    static let cellPaddingH: CGFloat = 10
    static let cellPaddingV: CGFloat = 7
    static let borderWidth: CGFloat = 0.5
    static let corner: CGFloat = 8

    /// The line grammar both surfaces speak — one truth, two renderers. A hairline
    /// between columns, a rule closing the header, and rows told apart by their
    /// wash rather than by a grid line. The SwiftUI surface draws its rim with a
    /// `RoundedRectangle` stroke (8 pt corners, which an `NSTextTableBlock` cannot
    /// round); the AppKit surface spells the same rim from the cell borders.
    static let columnRules = true
    static let headerRule = true
    static let rowRules = false

    private static var theme: SyntaxTheme { ThemeRegistry.shared.current }

    static var headerBackground: NSColor {
        let scope = theme.style(forScope: "markup.table.th")
        return scope.background
            ?? scope.foreground?.withAlphaComponent(0.16)
            ?? theme.sidebarAccent.withAlphaComponent(0.14)
    }

    static var headerForeground: NSColor {
        theme.style(forScope: "markup.table.th").foreground ?? theme.sidebarForeground
    }

    static var bodyForeground: NSColor { theme.sidebarForeground }

    static var border: NSColor { theme.rulerSeparator.withAlphaComponent(0.35) }

    /// Alternating row wash — even rows whisper, odd rows rest.
    static func rowTint(_ row: Int) -> NSColor {
        NSColor.labelColor.withAlphaComponent(row.isMultiple(of: 2) ? 0.025 : 0.055)
    }
}