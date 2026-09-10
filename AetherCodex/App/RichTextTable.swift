import AppKit

enum RichTextTable {
    static func make(_ rows: [[String]]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let table = NSTextTable()
        table.numberOfColumns = rows.map(\.count).max() ?? 1
        table.collapsesBorders = true
        let theme = ThemeRegistry.shared.current
        for (row, cells) in rows.enumerated() {
            for column in 0..<table.numberOfColumns {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(theme.rulerSeparator.withAlphaComponent(0.35))
                block.backgroundColor = theme.sidebarAccent.withAlphaComponent(row == 0 ? 0.14 : 0.035)
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = 0
                let text = column < cells.count ? cells[column] : ""
                let cell = NSMutableAttributedString(attributedString: MarkdownRichCodec.render(text + "\n"))
                let range = NSRange(location: 0, length: cell.length)
                cell.removeAttribute(MarkdownRichCodec.originalLine, range: range)
                cell.removeAttribute(MarkdownRichCodec.renderedLine, range: range)
                cell.addAttribute(.paragraphStyle, value: paragraph, range: range)
                result.append(cell)
            }
        }
        return result
    }
}
