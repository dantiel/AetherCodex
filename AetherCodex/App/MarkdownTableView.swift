import SwiftUI

/// Responsive markdown table for the oracle surface.
///
/// Cells share the hosting width equally and wrap their content, so every row
/// grows to its tallest cell and the table is never wider than the panel that
/// hosts it. There is deliberately **no** `ScrollView` and **no** fixed
/// `maxWidth`: either strips the width constraint, after which the row reports
/// an unbounded ideal width and pins each cell to one clipped line — the exact
/// defect this replaces (verified: 90 pt at every width before, 474/282/154 pt
/// across 200/340/680 pt now).
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    @Environment(\.markdownBodyScale) private var scale

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            row(header, header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                row(cells, header: false, zebra: index)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MarkdownTableStyle.corner))
        .overlay(
            RoundedRectangle(cornerRadius: MarkdownTableStyle.corner)
                .strokeBorder(Color(nsColor: MarkdownTableStyle.border), lineWidth: MarkdownTableStyle.borderWidth)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ cells: [String], header: Bool, zebra: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns, id: \.self) { column in
                cell(column < cells.count ? cells[column] : "", header: header, last: column == columns - 1)
            }
        }
        .background(header ? Color(nsColor: MarkdownTableStyle.headerBackground)
                           : Color(nsColor: zebra.map(MarkdownTableStyle.rowTint) ?? .clear))
        .overlay(alignment: .bottom) {
            if header ? MarkdownTableStyle.headerRule : MarkdownTableStyle.rowRules {
                Rectangle().fill(Color(nsColor: MarkdownTableStyle.border)).frame(height: MarkdownTableStyle.borderWidth)
            }
        }
    }

    private func cell(_ text: String, header: Bool, last: Bool) -> some View {
        Text(renderInline(text))
            .font(.system(size: markdownScaled(CGFloat(ThemeSettings.shared.proportionalFontSize), scale),
                          weight: header ? .semibold : .regular))
            .foregroundStyle(Color(nsColor: header ? MarkdownTableStyle.headerForeground : MarkdownTableStyle.bodyForeground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MarkdownTableStyle.cellPaddingH)
            .padding(.vertical, MarkdownTableStyle.cellPaddingV)
            .overlay(alignment: .trailing) {
                if !last && MarkdownTableStyle.columnRules {
                    Rectangle().fill(Color(nsColor: MarkdownTableStyle.border)).frame(width: MarkdownTableStyle.borderWidth)
                }
            }
    }
}