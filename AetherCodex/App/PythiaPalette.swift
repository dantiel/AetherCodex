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
    /// The oracle's voice — primary message-body text. Distinct from `foreground`
    /// (muted chrome/secondary). Argonaut declares golden amber; other themes
    /// derive it from their complementary tone (dark) or foreground (light).
    var baseText: NSColor
    var accent: NSColor
    var complementary: NSColor
    var codeBackground: NSColor
    var codeForeground: NSColor
    var shine: NSColor
    var glassTint: CGFloat
    var glassMaterialName: String?
    /// Prose font family for message bodies (nil = user's proportional font).
    /// Argonaut declares Syne — the original Pythia voice.
    var fontFamily: String?

    // MARK: SwiftUI projections

    var backgroundColor: Color { Color(nsColor: background) }
    var foregroundColor: Color { Color(nsColor: foreground) }
    var baseTextColor: Color { Color(nsColor: baseText) }
    var accentColor: Color { Color(nsColor: accent) }
    var complementaryColor: Color { Color(nsColor: complementary) }
    var codeBackgroundColor: Color { Color(nsColor: codeBackground) }
    var codeForegroundColor: Color { Color(nsColor: codeForeground) }
    var shineColor: Color { Color(nsColor: shine) }

    static func == (lhs: PythiaPalette, rhs: PythiaPalette) -> Bool {
        lhs.background.isEqual(rhs.background)
            && lhs.foreground.isEqual(rhs.foreground)
            && lhs.baseText.isEqual(rhs.baseText)
            && lhs.accent.isEqual(rhs.accent)
            && lhs.complementary.isEqual(rhs.complementary)
            && lhs.codeBackground.isEqual(rhs.codeBackground)
            && lhs.codeForeground.isEqual(rhs.codeForeground)
            && lhs.shine.isEqual(rhs.shine)
            && lhs.glassTint == rhs.glassTint
            && lhs.glassMaterialName == rhs.glassMaterialName
            && lhs.fontFamily == rhs.fontFamily
    }
}

extension PythiaPalette {
    /// Hermetic fallback — derive a chamber palette from the editor chrome.
    /// Same background/accent as the code, complementary hue for callouts,
    /// a slightly deepened code-preview surface, and a lifted "shine" tone.
    static func derive(background: NSColor,
                       foreground: NSColor,
                       accent: NSColor,
                       appearance: ThemeAppearance,
                       glassTint: CGFloat,
                       glassMaterialName: String?) -> PythiaPalette {
        let codeBackground = appearance == .dark
            ? background.mixed(with: .black, amount: 0.28)
            : background.mixed(with: .white, amount: 0.10)
        let shine = accent.mixed(with: appearance == .dark ? .white : .black, amount: 0.38)
        let complementary = accent.rotatingHue(by: 0.5)
        // The oracle's voice: dark chambers speak in the complementary tone
        // (Argonaut's golden amber), light chambers keep the legible foreground.
        let baseText = appearance == .dark ? complementary : foreground
        return PythiaPalette(
            background: background,
            foreground: foreground,
            baseText: baseText,
            accent: accent,
            complementary: complementary,
            codeBackground: codeBackground,
            codeForeground: foreground,
            shine: shine,
            glassTint: glassTint,
            glassMaterialName: glassMaterialName,
            fontFamily: nil
        )
    }

    /// Resolve the prose (message body) font — the theme's declared family
    /// (Syne for Argonaut) overrides the user's proportional font; the size
    /// still follows the user's preference so density stays user-controlled.
    var proseFont: NSFont {
        let size = ThemeSettings.shared.proportionalFontSize
        if let fam = fontFamily, let f = NSFont(name: fam, size: size) { return f }
        return ThemeSettings.shared.resolvedProportionalFont
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
        appearance: .dark,
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