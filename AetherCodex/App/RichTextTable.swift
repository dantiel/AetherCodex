import AppKit

enum RichTextTable {
    static func make(_ rows: [[String]]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let table = NSTextTable()
        table.numberOfColumns = rows.map(\.count).max() ?? 1
        table.collapsesBorders = true
        for (row, cells) in rows.enumerated() {
            let header = row == 0
            let lastRow = row == rows.count - 1
            for column in 0..<table.numberOfColumns {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                // Correspondence: the editable surface reads the same style truth
                // as the oracle surface (MarkdownTableView) — header wash, row wash,
                // border — so both render as one table.
                block.setBorderColor(MarkdownTableStyle.border)
                block.backgroundColor = header ? MarkdownTableStyle.headerBackground : MarkdownTableStyle.rowTint(row)
                // Innenabstand: derselbe Atem wie die SwiftUI-Fläche, per Kante —
                // `NSTextBlock` kennt keinen horizontalen/vertikalen Sammelwert.
                block.setWidth(MarkdownTableStyle.cellPaddingH, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(MarkdownTableStyle.cellPaddingH, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(MarkdownTableStyle.cellPaddingV, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(MarkdownTableStyle.cellPaddingV, type: .absoluteValueType, for: .padding, edge: .maxY)
                // Zeilen-Trenner: die Grammatik aus MarkdownTableStyle, per Kante
                // gesprochen — senkrechte Haarlinien, eine Unterkante der Kopfzeile,
                // kein waagerechtes Gitter im Körper (dort trennt der Wasch), und
                // ein Rahmen, der die Tabelle oben und unten schließt. Kollabieren
                // benachbarter Kanten lässt die dickere gewinnen.
                let lastColumn = column == table.numberOfColumns - 1
                let stroke = MarkdownTableStyle.borderWidth
                let top = header ? stroke : 0
                let bottom = (header && MarkdownTableStyle.headerRule) || lastRow || MarkdownTableStyle.rowRules ? stroke : 0
                let leading = column == 0 ? stroke : 0
                let trailing = lastColumn || MarkdownTableStyle.columnRules ? stroke : 0
                block.setWidth(top, type: .absoluteValueType, for: .border, edge: .minY)
                block.setWidth(bottom, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setWidth(leading, type: .absoluteValueType, for: .border, edge: .minX)
                block.setWidth(trailing, type: .absoluteValueType, for: .border, edge: .maxX)
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