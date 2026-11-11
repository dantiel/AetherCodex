import Foundation
import CoreGraphics

/// Single source of truth for the window's vertical chrome geometry.
///
/// Every "where does X start when the tab bar is visible?" question is answered
/// here, once, so the editor container, the code/rich-text scroll surfaces, and
/// their scroll indicators can never drift apart. The tab strip is the only row
/// that toggles; the title row is always present and always reserves its band.
enum EditorChromeMetrics {
    /// Inside NSTextView, so selection and line bands can paint to the gutter.
    static let codeLeadingPadding: CGFloat = 10
    /// Height of the title row (window title on the left, controls on the right).
    /// The title row now lives in the native toolbar, but the band it reserves
    /// stays 44 — the transparent titlebar lets content ride *under* the toolbar,
    /// so only the traffic-light row (~44) is cleared, not the full 52pt unified
    /// toolbar.
    static let titleBarBand: CGFloat = 44
    /// Height of the editor tab strip row.
    static let tabBarBand: CGFloat = 32
    /// The main window is borderless (its outer corner + shadow are self-drawn),
    /// so there is no titlebar to overhang into. The title band sits flush at the
    /// window's top edge and the tab strip begins directly beneath it.
    static let titleBarOverhang: CGFloat = 0

    /// Top edge of the floating tab strip, measured from the window's top edge —
    /// flush below the title band, since a borderless window owns no titlebar.
    static let tabStripTop: CGFloat = titleBarBand                     // 44
    /// Lower edge of the tab strip — anything that must sit *under* the strip
    /// (the Pythia inspector, the vertical scroller) tiles from here.
    static let tabStripBottom: CGFloat = tabStripTop + tabBarBand       // 76

    /// Breathing room above the first code line (two visual lines). This is part
    /// of the scroll content, so it scrolls away rather than becoming chrome.
    static let baseContentInset: CGFloat = 34
    /// A few extra pixels added to the code surface's first-line clearance only
    /// while the tab strip is shown, so the line never kisses the strip's shadow.
    static let tabBarContentClearance: CGFloat = 6
    /// One visual line of extra clearance below the tab strip for the trailing
    /// Pythia inspector, so its glass surface and header never kiss the strip.
    /// Applied on top of `tabStripBottom`; the no-tabbar case is flush to the top.
    static let pythiaBelowTabClearance: CGFloat = 20

    /// Legacy silhouette radius, now unused by the active window path. The main
    /// window is opaque + titled (`.windowStyle(.titleBar)`) + unified toolbar,
    /// so the window server owns the unified corner radius natively — no content
    /// clip. Kept only for `WindowChrome.ShadowRoundedView` (the retired
    /// borderless chrome).
    static let windowCornerRadius: CGFloat = 22
    /// Transparent rim around the content where the custom shadow has room to draw
    /// (a shadow cannot extend past its own window's bounds).
    static let windowShadowMargin: CGFloat = 26
    static let windowShadowRadius: CGFloat = 16
    static let windowShadowOpacity: Float = 0.4
    static let windowShadowOffsetY: CGFloat = 5

    /// Utility windows (`UtilityWindow` → `AppKitPanel`) round one point tighter.
    /// These stay titled; the value clips the *content* to match the native arc.
    static let utilityWindowCornerRadius: CGFloat = 15

    /// Height of the bottom status strip — one row of 11pt secondary text.
    static let statusBarHeight: CGFloat = 24
    /// Depth of the bottom progressive-blur ramp over the code column: the last
    /// lines dissolve into the status strip instead of being cut by it.
    static let scrollEdgeBlurDepth: CGFloat = 52
    /// Height of the floating quick-search pill's glass.
    static let quickSearchBarHeight: CGFloat = 36
    /// Clearance under the pill, measured from the text viewport's bottom edge.
    /// It lifts the pill above the horizontal scroller (which owns the last
    /// few points of the viewport) and leaves its shadow room to breathe.
    /// The pill floats — it never reserves a bar, so the code scrolls beneath it.
    static let quickSearchBarLift: CGFloat = 44
    /// Preferred width of the floating pill. Content stays readable and the
    /// pill reads as a tool, not a band; it is centred in the code column.
    static let quickSearchBarWidth: CGFloat = 300

    /// Extra scroll-content height for chrome rows (the tab strip) that sit above
    /// the surface. Zero when the strip is hidden.
    static func chromeInset(showsTabBar: Bool) -> CGFloat {
        showsTabBar ? tabBarBand : 0
    }

    /// Height owned by a scroll view's top safe-area bar. The tab strip is
    /// additional height, not its absolute bottom coordinate (which includes
    /// the title band already).
    static func scrollEdgeBarHeight(topInset: CGFloat) -> CGFloat {
        titleBarBand + max(0, topInset)
    }

    /// Top padding applied to the scroll content — the first line of the editor
    /// clears the title band plus any chrome row above it.
    static func contentTopInset(showsTabBar: Bool) -> CGFloat {
        baseContentInset + chromeInset(showsTabBar: showsTabBar)
    }

    /// Top margin for the vertical scroll indicator so it stops below the floating
    /// chrome instead of running up behind the transparent title/tab bar.
    static func scrollIndicatorTopInset(showsTabBar: Bool) -> CGFloat {
        showsTabBar ? tabStripBottom : titleBarBand
    }
}