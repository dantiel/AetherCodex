import SwiftUI

/// Shared chrome paint, including the exposed margin beneath the sidebar sheet.
/// Keep it behind content so tint never washes out labels or controls.
struct EditorChromeSurface: View {
    let color: NSColor
    /// Explicit tint opacity. `nil` (the default) honours the color's own alpha —
    /// theme colors already encode their transparency (e.g. `rulerBackground`'s
    /// 0.45 alpha). The old hardcoded 0.86 buried that and left the gutter opaque,
    /// so scroll content could never blur through the line-number column.
    var opacity: Double? = nil

    var body: some View {
        let effective = opacity ?? Double(color.alphaComponent)
        Rectangle().fill(.ultraThinMaterial)
            .overlay(Color(nsColor: color.withAlphaComponent(1)).opacity(effective))
            .allowsHitTesting(false)
    }
}

struct EditorStatusSurface: View {
    let theme: SyntaxTheme

    var body: some View {
        EditorChromeSurface(
            color: theme.rulerBackground,
            opacity: Double(ThemeSettings.shared.resolvedRulerBackgroundOpacity(for: theme))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: theme.rulerSeparator ?? .separatorColor))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Model

/// Aggregated status of the active document. Pushed up from the AppKit editor
/// (`EditorViewController.onStatusChange`) and observed by the bottom strip.
/// Lives on `TabsModel` so it survives tab switches — only the active tab writes.
final class EditorStatusModel: ObservableObject {
    @Published private(set) var language: String = "Plain Text"
    @Published private(set) var position: String = "Ln 1, Col 1"
    @Published private(set) var tabInfo: String = "Tab: 4"
    @Published private(set) var isDirty: Bool = false

    /// Assign only on a real change — the editor posts status on every caret
    /// move, and an unconditional `@Published` write re-evaluates the strip.
    func update(position: String, tabInfo: String, language: String, isDirty: Bool) {
        if self.position != position { self.position = position }
        if self.tabInfo != tabInfo { self.tabInfo = tabInfo }
        if self.language != language { self.language = language }
        if self.isDirty != isDirty { self.isDirty = isDirty }
    }

    /// Neutral state for tabs that own no text position (tasks, diffs, previews).
    func set(language: String) {
        update(position: "", tabInfo: "", language: language, isDirty: false)
    }
}

// MARK: - Strip

/// Bottom status strip: language on the leading edge, indent + caret position on
/// the trailing edge. Reads as chrome — one hairline, one material, no ornament.
struct EditorStatusBar: View {
    @ObservedObject var status: EditorStatusModel
    let theme: SyntaxTheme

    var body: some View {
        HStack(spacing: 14) {
            Text(status.language)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if status.isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes")
            }
            if !status.tabInfo.isEmpty { Text(status.tabInfo) }
            if !status.position.isEmpty { Text(status.position) }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: EditorChromeMetrics.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background { EditorStatusSurface(theme: theme) }
    }
}

// MARK: - Bottom band

/// The window's bottom safe-area band: only the always-present status strip.
/// The quick-search pill is a *floating overlay* (see `QuickSearchDock` mounted
/// by `EditorContainerView.overlay(alignment: .bottom)`), never a reserved band —
/// opening search never pushes the editor, the pill hovers above the strip and
/// the code scrolls beneath it through the bottom scroll-edge blur.
struct EditorBottomBar: View {
    @ObservedObject var status: EditorStatusModel
    let theme: SyntaxTheme
    /// Gates the status strip — View → Status Bar can hide it.
    var showStatusBar: Bool = true

    var body: some View {
        if showStatusBar {
            EditorStatusBar(status: status, theme: theme)
        }
    }
}