import SwiftUI

/// Shared chrome paint, including the exposed margin beneath the sidebar sheet.
/// Keep it behind content so tint never washes out labels or controls.
struct EditorChromeSurface: View {
    let color: NSColor
    var opacity: Double = 0.86

    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay(Color(nsColor: color.withAlphaComponent(1)).opacity(opacity))
            .allowsHitTesting(false)
    }
}

struct EditorStatusSurface: View {
    let theme: SyntaxTheme

    var body: some View {
        EditorChromeSurface(color: theme.rulerBackground, opacity: 0.55)
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

/// The window's bottom safe-area band: the docked quick-search bar (it grows in
/// above the status line when Ctrl+S opens it) over the always-present strip.
struct EditorBottomBar: View {
    /// Reference only — `QuickSearchDock` observes the model itself. Observing it
    /// here would re-evaluate `EditorContainerView`'s body per keystroke in the
    /// search field and tear the hosted inspector band down (see its header).
    let quickSearch: QuickSearchModel?
    @ObservedObject var status: EditorStatusModel
    let theme: SyntaxTheme

    var body: some View {
        VStack(spacing: 0) {
            if let quickSearch {
                QuickSearchDock(model: quickSearch)
            }
            EditorStatusBar(status: status, theme: theme)
        }
    }
}

/// The docked quick-search row. The row height animates 0 ⇄ its band while the
/// bar itself blurs/scales/fades — opening and folding are one motion. The bar
/// stays mounted for the whole life of a code tab (only its row collapses), so
/// the reveal can play in *and* out; folded, it takes no clicks.
private struct QuickSearchDock: View {
    @ObservedObject var model: QuickSearchModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            QuickSearchBar(model: model)
            Spacer(minLength: 0)
        }
        .frame(height: model.isVisible ? EditorChromeMetrics.quickSearchBarHeight : 0)
        .allowsHitTesting(model.isVisible)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.isVisible)
    }
}
