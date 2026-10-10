import SwiftUI

/// A bounded horizontal viewport keeps wide oracle tables inside their panel.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], header: true)
                    }
                }.background(Color(nsColor: headerBackground))
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
        let theme = ThemeRegistry.shared.current
        let headerStyle = theme.style(forScope: "markup.table.th")
        return Text(renderInline(text))
            .font(.system(size: ThemeSettings.shared.proportionalFontSize, weight: header ? .semibold : .regular))
            .foregroundStyle(Color(nsColor: header ? (headerStyle.foreground ?? theme.sidebarForeground) : theme.sidebarForeground))
            .textSelection(.enabled)
            // Wrap at the bounded column width instead of reporting a single-line
            // ideal size to the enclosing Grid (which otherwise pins every cell to
            // one horizontal line and pushes wide tables off-panel).
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 88, maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var headerBackground: NSColor {
        let theme = ThemeRegistry.shared.current
        let headerStyle = theme.style(forScope: "markup.table.th")
        return headerStyle.background ?? headerStyle.foreground?.withAlphaComponent(0.16) ?? theme.sidebarAccent.withAlphaComponent(0.14)
    }
}