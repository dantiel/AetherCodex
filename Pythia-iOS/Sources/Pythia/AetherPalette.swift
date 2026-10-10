import SwiftUI

/// The companion's color identity — discovered, not painted. Adaptive to the
/// system appearance so the app dissolves into the device the way the desktop
/// editor dissolves into the desktop.
public enum AetherPalette {
    public static var accent: Color {
        Color(light: Color(red: 0.42, green: 0.35, blue: 0.85),
              dark:  Color(red: 0.62, green: 0.52, blue: 1.0))
    }

    public static var surface: Color {
        Color(light: Color(red: 0.97, green: 0.96, blue: 0.98),
              dark:  Color(red: 0.10, green: 0.10, blue: 0.14))
    }

    public static var companionBubble: Color {
        accent.opacity(0.12)
    }
}

extension Color {
    /// Adaptive color that tracks the environment's color scheme. Cross-platform:
    /// resolves through UIColor on iOS and NSColor on macOS.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
        #else
        self = light
        #endif
    }
}
