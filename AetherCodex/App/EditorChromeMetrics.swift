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
    static let titleBarBand: CGFloat = 44
    /// Height of the editor tab strip row.
    static let tabBarBand: CGFloat = 32
    /// How far the title row overhangs upward into the window's title bar (it is
    /// drawn `.offset(y: -titleBarOverhang)` so its glyphs sit in the traffic-light
    /// row, but its interactive row still occupies the full `titleBarBand`).
    static let titleBarOverhang: CGFloat = 28

    /// Top edge of the floating tab strip, measured from the window's top edge.
    /// The strip overhangs the lower half of the title band.
    static let tabStripTop: CGFloat = titleBarBand - titleBarOverhang   // 16
    /// Lower edge of the tab strip — anything that must sit *under* the strip
    /// (the Pythia inspector, the vertical scroller) tiles from here.
    static let tabStripBottom: CGFloat = tabStripTop + tabBarBand       // 48

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

    /// Extra scroll-content height for chrome rows (the tab strip) that sit above
    /// the surface. Zero when the strip is hidden.
    static func chromeInset(showsTabBar: Bool) -> CGFloat {
        showsTabBar ? tabBarBand : 0
    }

    /// Top padding applied to the scroll content — the first line of the editor
    /// clears the title band plus any chrome row above it.
    static func contentTopInset(showsTabBar: Bool) -> CGFloat {
        baseContentInset + chromeInset(showsTabBar: showsTabBar)
    }

    /// Top margin for the vertical scroll indicator so it stops below the floating
    /// chrome instead of running up behind the transparent title/tab bar.
    static func scrollIndicatorTopInset(showsTabBar: Bool) -> CGFloat {
        showsTabBar ? tabStripBottom : titleBarOverhang
    }
}
