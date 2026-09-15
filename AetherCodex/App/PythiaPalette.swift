import Cocoa
import SwiftUI

// MARK: - Pythia Oracle Chamber Palette

/// The Pythia oracle chamber's color identity — the "quantum æther" surface
/// that mirrors the code editor's theme. A theme may declare a first-class
/// `pythia:` block (Argonaut does). When it does not, the palette is
/// hermetically derived from the editor chrome: same background + accent, a
/// complementary hue for callouts, a dedicated code-preview surface, and a
/// "shine" tone for tool-call results.
struct PythiaPalette: Equatable {
    var background: NSColor
    var foreground: NSColor
    var accent: NSColor
    var complementary: NSColor
    var codeBackground: NSColor
    var codeForeground: NSColor
    var shine: NSColor
    var glassTint: CGFloat
    var glassMaterialName: String?

    // MARK: SwiftUI projections

    var backgroundColor: Color { Color(nsColor: background) }
    var foregroundColor: Color { Color(nsColor: foreground) }
    var accentColor: Color { Color(nsColor: accent) }
    var complementaryColor: Color { Color(nsColor: complementary) }
    var codeBackgroundColor: Color { Color(nsColor: codeBackground) }
    var codeForegroundColor: Color { Color(nsColor: codeForeground) }
    var shineColor: Color { Color(nsColor: shine) }

    static func == (lhs: PythiaPalette, rhs: PythiaPalette) -> Bool {
        lhs.background.isEqual(rhs.background)
            && lhs.foreground.isEqual(rhs.foreground)
            && lhs.accent.isEqual(rhs.accent)
            && lhs.complementary.isEqual(rhs.complementary)
            && lhs.codeBackground.isEqual(rhs.codeBackground)
            && lhs.codeForeground.isEqual(rhs.codeForeground)
            && lhs.shine.isEqual(rhs.shine)
            && lhs.glassTint == rhs.glassTint
            && lhs.glassMaterialName == rhs.glassMaterialName
    }
}

extension PythiaPalette {
    /// Hermetic fallback — derive a chamber palette from the editor chrome.
    /// Same background/accent as the code, complementary hue for callouts,
    /// a slightly deepened code-preview surface, and a lifted "shine" tone.
    static func derive(background: NSColor,
                       foreground: NSColor,
                       accent: NSColor,
                       kind: ThemeKind,
                       glassTint: CGFloat,
                       glassMaterialName: String?) -> PythiaPalette {
        let codeBackground = kind == .dark
            ? background.mixed(with: .black, amount: 0.28)
            : background.mixed(with: .white, amount: 0.10)
        let shine = accent.mixed(with: kind == .dark ? .white : .black, amount: 0.38)
        return PythiaPalette(
            background: background,
            foreground: foreground,
            accent: accent,
            complementary: accent.rotatingHue(by: 0.5),
            codeBackground: codeBackground,
            codeForeground: foreground,
            shine: shine,
            glassTint: glassTint,
            glassMaterialName: glassMaterialName
        )
    }
}

// MARK: - Environment propagation

/// Carries the active theme's chamber palette into the Pythia view subtree so
/// sibling views (pills, pickers, tool chips, input bar) share one identity
/// without threading the palette through every initializer.
private struct PythiaPaletteKey: EnvironmentKey {
    static let defaultValue = PythiaPalette.derive(
        background: .windowBackgroundColor,
        foreground: .labelColor,
        accent: .controlAccentColor,
        kind: .dark,
        glassTint: 0.7,
        glassMaterialName: nil
    )
}

extension EnvironmentValues {
    var pythiaPalette: PythiaPalette {
        get { self[PythiaPaletteKey.self] }
        set { self[PythiaPaletteKey.self] = newValue }
    }
}

// MARK: - Color utilities

extension NSColor {
    /// Rotate hue by a fraction of the wheel (0.5 = complementary).
    func rotatingHue(by delta: CGFloat) -> NSColor {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + delta).truncatingRemainder(dividingBy: 1.0),
                       saturation: s, brightness: b, alpha: a)
    }

    /// Linear blend toward another color (0.0 = self, 1.0 = other).
    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        let a = usingColorSpace(.deviceRGB) ?? self
        let b = other.usingColorSpace(.deviceRGB) ?? other
        let t = min(max(amount, 0), 1)
        return NSColor(red: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }
}
