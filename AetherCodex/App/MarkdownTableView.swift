import SwiftUI

/// A bounded horizontal viewport keeps wide oracle tables inside their panel.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let theme = ThemeRegistry.shared.current
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], header: true)
                    }
                }.background(Color(nsColor: theme.sidebarAccent).opacity(0.14))
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<max(header.count, rows[row].count), id: \.self) { column in
                            cell(column < rows[row].count ? rows[row][column] : "", header: false)
                        }
                    }.background(Color.primary.opacity(row.isMultiple(of: 2) ? 0.025 : 0.055))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.18)))
    }

    private func cell(_ text: String, header: Bool) -> some View {
        Text(renderInline(text))
            .font(.system(size: ThemeSettings.shared.proportionalFontSize, weight: header ? .semibold : .regular))
            .textSelection(.enabled)
            .frame(minWidth: 88, maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
