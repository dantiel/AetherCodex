import SwiftUI

/// Bottom tab bar of the left sidebar — the four pane switchers (Files,
/// Favourites, Search, Git) float as a glass capsule *inside* the sheet, docked
/// to its lower edge. The selected pane glows in the theme accent, siblings rest
/// in secondary.
///
/// The bar is declared *inside each pane's own SwiftUI graph* — the same shape
/// Pythia's composer takes — because only there does the compositor learn the
/// bar's extent. Declared on the AppKit bridge instead (where the sidebar's
/// hosted NSView lives), the scroll view never hears of it: the soft scroll-edge
/// effect collapses to a few pixels and the last row rests beneath the glass.
struct SidebarTabBar: View {
    @ObservedObject var chrome: EditorChromeState

    private var accent: Color { Color(nsColor: chrome.theme.sidebarAccent) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(chrome.sidebarTabs, id: \.id) { tab in
                let isSelected = chrome.selectedSidebarTab == tab.id
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        chrome.selectedSidebarTab = tab.id
                    }
                    chrome.onSidebarTabSelected?(tab.id)
                } label: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 36, height: 28)
                        .foregroundStyle(isSelected ? accent : Color.secondary)
                        .background(isSelected ? accent.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.tooltip)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }
}

extension View {
    /// Dock the sidebar pane switcher to this view's lower edge. Applied to a
    /// pane's own scroller, `safeAreaBar` hands the bar's height to the scroll
    /// view as a content inset *and* gives the compositor the extent of the soft
    /// scroll-edge blur — the row clears the capsule while the content keeps
    /// travelling beneath it. No manual content margin, no bridge-level bar.
    func sidebarTabBar(_ chrome: EditorChromeState) -> some View {
        safeAreaBar(edge: .bottom, spacing: 0) {
            SidebarTabBar(chrome: chrome)
                .frame(height: SidebarSheetGeometry.tabBarBand)
        }
    }
}
