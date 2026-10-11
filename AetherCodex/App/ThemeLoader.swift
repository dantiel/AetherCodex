import Cocoa
import AetherOracleResources

// MARK: - YAML Theme Loader

/// Loads theme definitions from YAML files in Resources/Themes/.
/// Supports two scope formats:
///   keyword: "0xRRGGBB"           → color-only
///   keyword: { color: "0xRRGGBB", bold: true, italic: true }  → color + traits
enum ThemeLoader {

    // MARK: - Loading

    /// Load all .yml files from Resources/Themes/.
    static func loadAll() -> [SyntaxTheme] {
        guard let themeDir = themeResourcesDirectory() else {
            print("[ThemeLoader] Themes directory not found in bundle")
            return []
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: themeDir, includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "yml" }
            .compactMap { loadTheme(from: $0.path) }
    }

    /// Locate Resources/Themes/ — tries AetherOracleResources.bundle first (SPM), then Bundle.main (app bundle).
    private static func themeResourcesDirectory() -> URL? {
        // 1. SPM AetherOracleResources.bundle (works when run from .build/debug/)
        if let dir = AetherOracleResources.bundle.url(forResource: "Themes", withExtension: nil) {
            return dir
        }
        // 2. App bundle (when bundled via bundle_app.sh)
        if let resURL = Bundle.main.resourceURL {
            let themesDir = resURL.appendingPathComponent("Themes")
            if FileManager.default.fileExists(atPath: themesDir.path) {
                return themesDir
            }
        }
        // 3. Relative path from executable (dev workflow)
        let devPath = URL(fileURLWithPath: "AetherCodex/Resources/resources/Themes")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        return nil
    }

    // MARK: - Theme from YAML dict

    static func loadTheme(from path: String) -> SyntaxTheme? {
        let dict = SimpleYaml.loadFile(path)
        return theme(from: dict)
    }

    static func theme(from dict: [String: Any]) -> SyntaxTheme? {
        guard let name = dict["name"] as? String,
              let appearanceStr = (dict["appearance"] ?? dict["kind"]) as? String,
              let appearance = ThemeAppearance(rawValue: appearanceStr),
              let scopes = dict["scopes"] as? [String: Any]
        else {
            print("[ThemeLoader] invalid theme: missing name/appearance/scopes")
            return nil
        }

        // Parse scope styles — store both TokenScope-keyed (for fast lookup)
        // AND string-keyed (for cascade prefix resolution).
        var scopeStyles: [TokenScope: TokenStyle] = [:]
        var rawScopeStyles: [String: TokenStyle] = [:]
        for (scopeName, value) in scopes {
            let style = parseStyle(value)
            rawScopeStyles[scopeName] = style
            if let scope = TokenScope(rawValue: scopeName) {
                scopeStyles[scope] = style
            }
        }

        // Parse editor chrome — support both top-level and nested `editor:` block
        let editorDict     = dict["editor"] as? [String: Any]
        let backgroundSrc  = dict["editorBackground"] ?? editorDict?["background"] ?? editorDict?["backgroundColor"]
        let foregroundSrc  = dict["editorForeground"] ?? editorDict?["foreground"] ?? editorDict?["foregroundColor"]
        let caretSrc       = dict["caretColor"]        ?? editorDict?["caret"]   ?? editorDict?["cursorColor"]
        let selectionSrc   = dict["selectionColor"]    ?? editorDict?["selection"]
        let lineHlSrc      = dict["lineHighlight"]     ?? editorDict?["lineHighlight"] ?? editorDict?["currentLine"]
        let invisiblesSrc  = dict["invisiblesColor"]   ?? editorDict?["invisibles"]

        let editorBackground = parseColor(backgroundSrc) ?? NSColor(white: 0.08, alpha: 1.0)
        let editorForeground = parseColor(foregroundSrc) ?? NSColor(white: 0.70, alpha: 1.0)
        let caretColor       = parseColor(caretSrc) ?? .white
        let selectionColor   = parseColor(selectionSrc)
            ?? NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 1.0)
        let lineHighlight    = parseColor(lineHlSrc)
            ?? NSColor(white: 0.12, alpha: 1.0)
        let gutterSelBg      = parseColor(dict["gutterSelectionBackground"])
            ?? NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 0.4)
        let gutterSelFg      = parseColor(dict["gutterSelectionForeground"])
            ?? NSColor(white: 0.85, alpha: 1.0)
        let gutterSelBorder  = parseColor(dict["gutterSelectionBorder"])
            ?? NSColor(red: 0.00, green: 0.22, blue: 0.44, alpha: 0.8)
        let rulerBg       = parseColor(dict["rulerBackground"])
        let rulerSep      = parseColor(dict["rulerSeparator"])

        // Graphical effects — use Double→CGFloat conversion (SimpleYaml returns Double)
        let opacity    = (dict["editorBackgroundOpacity"] as? Double).map { CGFloat($0) } ?? 0.0
        let shadow     = (dict["textShadowStrength"] as? Double).map { CGFloat($0) } ?? 0.6
        let spacing    = (dict["lineSpacing"] as? Double).map { CGFloat($0) } ?? 4.0
        let blurMat    = parseMaterial(dict["rootBlurMaterial"])
        let blendMode  = parseBlendMode(dict["rootBlendingMode"])
        let pythiaMat  = parseMaterial(dict["pythiaGlassMaterial"])
        let glassTintColor = parseColor(dict["glassTintColor"])
            ?? NSColor(white: 0.5, alpha: 0.15)
        let glassStyleVal = parseGlassStyle(dict["glassStyle"])
        let sideBg     = parseColor(dict["sidebarBackground"])
        let sideOp     = (dict["sidebarBackgroundOpacity"] as? Double).map { CGFloat($0) }
        let glassTintStrength = parseAlphaValue(dict["glassTint"]) ?? 0.70
        let glassBlurStrength = parseAlphaValue(dict["glassBlurStrength"]) ?? 0.50
        let sideMat    = dict["sidebarGlassMaterial"] as? String

        // Pythia oracle chamber palette — merge first-class `pythia:` block over
        // the hermetically derived per-theme fallback (same/complementary colors).
        let pythiaDict = dict["pythia"] as? [String: Any]
        let pythiaBase = PythiaPalette.derive(
            background: sideBg ?? editorBackground,
            foreground: editorForeground,
            accent: parseColor(dict["sidebarAccent"]) ?? selectionColor,
            appearance: appearance,
            glassTint: glassTintStrength,
            glassMaterialName: sideMat
        )
        // Base text fallback honors the curated block's own character tone:
        // dark chambers adopt the declared `complementary`, light chambers the
        // declared `foreground` — falling back to the derived palette only when
        // the block omits them.
        let pythiaBaseTextFallback: NSColor? = appearance == .dark
            ? parseColor(pythiaDict?["complementary"])
            : parseColor(pythiaDict?["foreground"])

        let pythia = PythiaPalette(
            background: parseColor(pythiaDict?["background"]) ?? pythiaBase.background,
            foreground: parseColor(pythiaDict?["foreground"]) ?? pythiaBase.foreground,
            baseText: parseColor(pythiaDict?["baseText"]) ?? pythiaBaseTextFallback ?? pythiaBase.baseText,
            accent: parseColor(pythiaDict?["accent"]) ?? pythiaBase.accent,
            complementary: parseColor(pythiaDict?["complementary"]) ?? pythiaBase.complementary,
            codeBackground: parseColor(pythiaDict?["codeBackground"]) ?? pythiaBase.codeBackground,
            codeForeground: parseColor(pythiaDict?["codeForeground"]) ?? pythiaBase.codeForeground,
            shine: parseColor(pythiaDict?["shine"]) ?? pythiaBase.shine,
            glassTint: parseAlphaValue(pythiaDict?["glassTint"]) ?? pythiaBase.glassTint,
            glassMaterialName: (pythiaDict?["glassMaterial"] as? String) ?? pythiaBase.glassMaterialName,
            fontFamily: pythiaDict?["fontFamily"] as? String
        )

        let tags = (dict["tags"] as? [Any]).flatMap { $0 as? [String] } ?? []
        let themeClass = dict["class"] as? String

        return LoadedTheme(
            name: name,
            appearance: appearance,
            tags: tags,
            themeClass: themeClass,
            scopeStyles: scopeStyles,
            rawScopeStyles: rawScopeStyles,
            editorBackground: editorBackground,
            editorForeground: editorForeground,
            caretColor: caretColor,
            selectionColor: selectionColor,
            lineHighlight: lineHighlight,
            gutterSelectionBackground: gutterSelBg,
            gutterSelectionForeground: gutterSelFg,
            gutterSelectionBorder: gutterSelBorder,
            rulerBackground: rulerBg ?? editorBackground,
            rulerSeparator: rulerSep ?? editorForeground.withAlphaComponent(0.40),
            editorBackgroundOpacity: opacity,
            sidebarBackground: sideBg,
            sidebarBackgroundOpacity: sideOp,
            textShadowStrength: shadow,
            lineSpacing: spacing,
            glassTintColor: glassTintColor,
            glassStyle: glassStyleVal,
            glassTint: glassTintStrength,
            glassBlurStrength: glassBlurStrength,
            rootBlurMaterial: blurMat,
            rootBlendingMode: blendMode,
            pythiaGlassMaterial: pythiaMat,
            sidebarGlassMaterialName: sideMat,
            pythia: pythia,
            rulerForeground: parseColor(dict["rulerForeground"]) ?? editorForeground.withAlphaComponent(0.65),
            rulerFontSize: (dict["rulerFontSize"] as? Double).map { CGFloat($0) },
            sidebarAccent: parseColor(dict["sidebarAccent"]) ?? selectionColor.withAlphaComponent(1),
            sidebarForeground: parseColor(dict["sidebarForeground"]) ?? editorForeground
        )
    }

    // MARK: - Value Parsers

    private static func parseStyle(_ value: Any) -> TokenStyle {
        // Handle Optional wrapping from YAML parsing
        let unwrapped: Any = {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let some = mirror.children.first?.value { return some }
                return value
            }
            return value
        }()
        
        // Simple color value: "0xRRGGBB" string OR integer like 0xC759C7
        if let hexString = unwrapped as? String {
            return TokenStyle(parseColor(hexString) ?? .white)
        }
        if let hexInt = unwrapped as? Int {
            return TokenStyle(NSColor(
                red: CGFloat((hexInt >> 16) & 0xFF) / 255.0,
                green: CGFloat((hexInt >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hexInt & 0xFF) / 255.0,
                alpha: 1.0
            ))
        }
        // Handle Double from YAML (e.g., 13071687.0 for 0xC759C7)
        if let hexDouble = unwrapped as? Double {
            let hexInt = Int(hexDouble)
            return TokenStyle(NSColor(
                red: CGFloat((hexInt >> 16) & 0xFF) / 255.0,
                green: CGFloat((hexInt >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hexInt & 0xFF) / 255.0,
                alpha: 1.0
            ))
        }

        // Style map: { color: ..., bold: true/false, ... }
        if let map = unwrapped as? [String: Any] {
            // nil foreground = inherit from cascade parent (TextMate convention)
            let fg = parseColorOrInt(map["color"])
            let bg = parseColorOrInt(map["background"])
            // Traits: nil = inherit, true/false = explicit. Only set when key present.
            let bold: Bool? = (map["bold"] as? Bool)
            let italic: Bool? = (map["italic"] as? Bool)
            let underline: Bool? = (map["underline"] as? Bool)
            let strikethrough: Bool? = (map["strikethrough"] as? Bool)
                ?? (map["markup.strikethrough"] as? Bool)
            let fontName = map["fontName"] as? String
            let fontSize = map["fontSize"] as? Double
            return TokenStyle(fg, bg: bg, bold: bold, italic: italic, underline: underline,
                              strikethrough: strikethrough,
                              fontName: fontName, fontSize: fontSize.map { CGFloat($0) })
        }

        return TokenStyle(.white)
    }

    // Helper to handle both String ("0xRRGGBB") and Int (0xRRGGBB) color values
    private static func parseColorOrInt(_ value: Any?) -> NSColor? {
        if let s = value as? String { return parseColor(s) }
        if let i = value as? Int {
            return NSColor(
                red: CGFloat((i >> 16) & 0xFF) / 255.0,
                green: CGFloat((i >> 8) & 0xFF) / 255.0,
                blue: CGFloat(i & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        return nil
    }

    private static func parseColor(_ value: Any?) -> NSColor? {
        guard let hexStr = value as? String else {
            return nil
        }

        // Support 0xRRGGBB, #RRGGBB, and plain RRGGBB
        var cleaned = hexStr.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        if cleaned.lowercased().hasPrefix("0x") { cleaned = String(cleaned.dropFirst(2)) }
        if cleaned.hasPrefix("#")  { cleaned = String(cleaned.dropFirst()) }

        // Support 6-char (RRGGBB) and 8-char (RRGGBBAA) hex
        let isValid6 = cleaned.count == 6
        let isValid8 = cleaned.count == 8
        guard (isValid6 || isValid8),
              let hex = UInt32(cleaned, radix: 16) else {
            print("[ThemeLoader] parseColor: invalid hex '\(cleaned)' from '\(hexStr)'")
            return nil
        }

        if isValid8 {
            return NSColor(
                red:   CGFloat((hex >> 24) & 0xFF) / 255.0,
                green: CGFloat((hex >> 16) & 0xFF) / 255.0,
                blue:  CGFloat((hex >>  8) & 0xFF) / 255.0,
                alpha: CGFloat( hex        & 0xFF) / 255.0
            )
        }
        return NSColor(
            red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >>  8) & 0xFF) / 255.0,
            blue:  CGFloat( hex        & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private static func parseMaterial(_ value: Any?) -> NSVisualEffectView.Material {
        guard let str = value as? String else { return .fullScreenUI }
        switch str {
        case "fullScreenUI":           return .fullScreenUI
        case "underWindowBackground":  return .underWindowBackground
        case "menu":                   return .menu
        case "sidebar":                return .sidebar
        case "headerView":             return .headerView
        case "popover":                return .popover
        case "hudWindow":              return .hudWindow
        case "toolTip":                return .toolTip
        case "sheet":                  return .sheet
        default:                       return .fullScreenUI
        }
    }

    private static func parseBlendMode(_ value: Any?) -> NSVisualEffectView.BlendingMode {
        guard let str = value as? String else { return .behindWindow }
        switch str {
        case "behindWindow": return .behindWindow
        case "withinWindow": return .withinWindow
        default:             return .behindWindow
        }
    }

    private static func parseGlassStyle(_ value: Any?) -> NSGlassEffectView.Style {
        guard let str = value as? String else { return .regular }
        switch str {
        case "clear":   return .clear
        default:        return .regular
        }
    }

    private static func parseAlphaValue(_ value: Any?) -> CGFloat? {
        if let d = value as? Double { return CGFloat(d) }
        if let i = value as? Int { return CGFloat(i) / 100.0 }
        if let s = value as? String {
            var cleaned = s.trimmingCharacters(in: .whitespaces)
            if cleaned.hasSuffix("%") {
                cleaned = String(cleaned.dropLast())
                return CGFloat(Double(cleaned) ?? 0) / 100.0
            }
            return CGFloat(Double(cleaned) ?? 0)
        }
        return nil
    }
}

// MARK: - Runtime Theme Wrapper

/// Concrete `SyntaxTheme` loaded from YAML.
private struct LoadedTheme: SyntaxTheme {
    let name: String
    let appearance: ThemeAppearance
    let tags: [String]
    let themeClass: String?
    let scopeStyles: [TokenScope: TokenStyle]
    /// String-keyed copy for cascade prefix resolution (includes intermediate
    /// scopes like "markup.heading" that have no TokenScope case).
    let rawScopeStyles: [String: TokenStyle]

    // Chrome
    let editorBackground: NSColor
    let editorForeground: NSColor
    let caretColor: NSColor
    let selectionColor: NSColor
    let lineHighlight: NSColor
    let gutterSelectionBackground: NSColor
    let gutterSelectionForeground: NSColor
    let gutterSelectionBorder: NSColor
    let rulerBackground: NSColor
    let rulerSeparator: NSColor

    // Effects
    let editorBackgroundOpacity: CGFloat
    let sidebarBackground: NSColor?
    let sidebarBackgroundOpacity: CGFloat?
    let textShadowStrength: CGFloat
    let lineSpacing: CGFloat
    let glassTintColor: NSColor
    let glassStyle: NSGlassEffectView.Style
    let glassTint: CGFloat
    let glassBlurStrength: CGFloat
    let rootBlurMaterial: NSVisualEffectView.Material
    let rootBlendingMode: NSVisualEffectView.BlendingMode
    let pythiaGlassMaterial: NSVisualEffectView.Material
    let sidebarGlassMaterialName: String?
    let pythia: PythiaPalette
    var rulerForeground: NSColor = .secondaryLabelColor
    var rulerFontSize: CGFloat? = nil
    var sidebarAccent: NSColor = .controlAccentColor
    var sidebarForeground: NSColor = .labelColor

    func style(for scope: TokenScope) -> TokenStyle {
        return resolveStyle(scopeName: scope.rawValue)
    }

    /// String-based scope resolution for any TextMate scope name.
    func style(forScope scopeName: String) -> TokenStyle {
        return resolveStyle(scopeName: scopeName)
    }

    /// Shared resolution: plain → prefix cascade → editor foreground fallback.
    private func resolveStyle(scopeName: String) -> TokenStyle {
        var merged: TokenStyle?

        // Start with `plain` base if defined (TextMate global/default scope).
        // Strip background — plain's bg is the editor backdrop, not a token background.
        if let plainStyle = rawScopeStyles["plain"] {
            merged = TokenStyle(
                plainStyle.foreground,
                bg: nil,
                bold: plainStyle.isBold,
                italic: plainStyle.isItalic,
                underline: plainStyle.isUnderline,
                strikethrough: plainStyle.isStrikethrough,
                fontName: plainStyle.fontName,
                fontSize: plainStyle.fontSize
            )
        }

        // Walk prefix hierarchy: "entity.name.class" → "entity.name" → "entity"
        let parts = scopeName.split(separator: ".")
        var current = ""
        for (i, part) in parts.enumerated() {
            current = i == 0 ? String(part) : "\(current).\(part)"
            if let style = rawScopeStyles[current] {
                merged = merge(base: merged, override: style)
            }
        }

        // Fall back to scopeStyles dict for any legacy lookup
        if merged == nil, let scope = TokenScope(rawValue: scopeName),
           let style = scopeStyles[scope] {
            merged = style
        }

        // Emphasis markup deserves a *distinct* accent color, not just a weight/
        // slant change. Most themes set `markup.bold`/`markup.italic` to the
        // editor foreground (or leave them colorless), which reads as plain text
        // with a font change. Derive warm/cool accents so bold and italic voice
        // is visible as color. Explicit non-foreground colors are respected.
        if scopeName == "markup.bold" || scopeName == "markup.italic" {
            let explicit = rawScopeStyles[scopeName]?.foreground
            let needsAccent = explicit == nil || (explicit.map { Self.isNear($0, editorForeground) } ?? true)
            if needsAccent {
                let style = merged ?? TokenStyle(editorForeground)
                merged = TokenStyle(emphasisAccent(for: scopeName),
                                    bg: style.background,
                                    bold: style.isBold ?? (scopeName == "markup.bold"),
                                    italic: style.isItalic ?? (scopeName == "markup.italic"),
                                    underline: style.isUnderline,
                                    strikethrough: style.isStrikethrough,
                                    fontName: style.fontName,
                                    fontSize: style.fontSize)
            }
        }

        return merged ?? TokenStyle(editorForeground)
    }

    /// Warm amber for bold, cool violet for italic — legible on dark and light.
    private func emphasisAccent(for scopeName: String) -> NSColor {
        let fg = editorForeground.usingColorSpace(.sRGB) ?? editorForeground
        let isDark = fg.brightnessComponent < 0.5
        let hue: CGFloat = scopeName == "markup.bold" ? 0.11 : 0.68
        let brightness: CGFloat = isDark ? 0.82 : 0.44
        return NSColor(calibratedHue: hue, saturation: 0.60, brightness: brightness, alpha: 1)
    }

    private static func isNear(_ a: NSColor, _ b: NSColor) -> Bool {
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        return abs(ca.redComponent - cb.redComponent) < 0.03
            && abs(ca.greenComponent - cb.greenComponent) < 0.03
            && abs(ca.blueComponent - cb.blueComponent) < 0.03
    }

    /// Merge two TokenStyles: override non-nil values win; nil falls back to base.
    private func merge(base: TokenStyle?, override: TokenStyle) -> TokenStyle {
        guard let b = base else { return override }
        // Bool? merge: override non-nil takes precedence, else inherit from base
        let mergedBold: Bool? = override.isBold ?? b.isBold
        let mergedItalic: Bool? = override.isItalic ?? b.isItalic
        let mergedUnderline: Bool? = override.isUnderline ?? b.isUnderline
        let mergedStrikethrough: Bool? = override.isStrikethrough ?? b.isStrikethrough
        return TokenStyle(
            override.foreground ?? b.foreground,
            bg: override.background ?? b.background,
            bold: mergedBold,
            italic: mergedItalic,
            underline: mergedUnderline,
            strikethrough: mergedStrikethrough,
            fontName: override.fontName ?? b.fontName,
            fontSize: override.fontSize ?? b.fontSize
        )
    }
}

// MARK: - Built-in Fallback Themes

extension ThemeLoader {
    /// Absolute last-resort theme — guaranteed non-nil, used when everything else fails.
    static func fallbackTheme() -> SyntaxTheme {
        LoadedTheme(
            name: "Fallback",
            appearance: .dark,
            tags: [],
            themeClass: nil,
            scopeStyles: [:],
            rawScopeStyles: [:],
            editorBackground: NSColor(white: 0.08, alpha: 1.0),
            editorForeground: NSColor(white: 0.70, alpha: 1.0),
            caretColor: .white,
            selectionColor: NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 1.0),
            lineHighlight: NSColor(white: 0.12, alpha: 1.0),
            gutterSelectionBackground: NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 0.4),
            gutterSelectionForeground: NSColor(white: 0.85, alpha: 1.0),
            gutterSelectionBorder: NSColor(red: 0.00, green: 0.22, blue: 0.44, alpha: 0.8),
            rulerBackground: NSColor(white: 0.10, alpha: 0.45),
            rulerSeparator: NSColor(white: 0.25, alpha: 0.6),
            editorBackgroundOpacity: 0.0,
            sidebarBackground: nil,
            sidebarBackgroundOpacity: nil,
            textShadowStrength: 0.6,
            lineSpacing: 4.0,
            glassTintColor: NSColor(white: 0.5, alpha: 0.15),
            glassStyle: .regular,
            glassTint: 0.70,
            glassBlurStrength: 0.50,
            rootBlurMaterial: .fullScreenUI,
            rootBlendingMode: .behindWindow,
            pythiaGlassMaterial: .menu,
            sidebarGlassMaterialName: nil,
            pythia: PythiaPalette.derive(
                background: NSColor(white: 0.08, alpha: 1.0),
                foreground: NSColor(white: 0.70, alpha: 1.0),
                accent: NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 1.0),
                appearance: .dark,
                glassTint: 0.70,
                glassMaterialName: nil
            )
        )
    }

    /// Hardcoded fallback themes — used only if YAML resources are missing.
    static func builtInThemes() -> [SyntaxTheme] {
        let hermeticYaml = """
        name: Hermetic
        appearance: dark
        scopes:
          keyword: "0xC759C7"
          keyword.type: "0xB08AD9"
          operator: "0xD999D9"
          string: "0x73BF73"
          string.escape: "0xA0A3F9"
          constant.numeric: "0xD9B373"
          comment: "0x666666"
          type: "0x8CB3D9"
          support.type: "0x7A88F6"
          function: "0xB3BFD9"
          support.function: "0x815DB3"
          variable: "0xCCCCBF"
          variable.language: "0x0068C5"
          variable.instance: "0x62A6FF"
          variable.class: "0x7A88F6"
          variable.global: "0xF18F94"
          constant: "0xA4ED2D"
          constant.symbol: "0xA4ED2D"
          support.constant: "0x06960E"
          property: "0xA6BFCC"
          punctuation: "0x808080"
          tag: "0x0065D3"
          attribute: "0x7A88F6"
          markup.heading: "0x62A6FF"
          markup.link: "0x62A6FF"
          markup.link.url: "0x7EC8FF"
          markup: "0xFFCA00"
          preprocessor: "0x7B9A00"
          invalid: "0xFF0000"
          markup.italic:
            color: "0xB0E0C0"
            italic: true
          markup.bold:
            color: "0xF0E8A0"
            bold: true
          markup.strikethrough:
            color: "0x996666"
            background: "0x1A1010"
            strikethrough: true
          markup.quote:
            color: "0x9999B3"
            italic: true
            background: "0x141420"
          markup.rule:
            color: "0x665580"
            bold: true
          markup.code.block:
            color: "0x8CB3BF"
            background: "0x0E1418"
          markup.list.checked:
            color: "0x73BF73"
            background: "0x0A1A0A"
            bold: true
          plain: "0xBFBFB8"
        editorBackground: "0x141414"
        editorForeground: "0xBFBFB8"
        caretColor: "0xFFFFFF"
        selectionColor: "0x002E54"
        lineHighlight: "0x1E1E1E"
        editorBackgroundOpacity: 0.0
        textShadowStrength: 0.6
        lineSpacing: 4.0
        rootBlurMaterial: fullScreenUI
        rootBlendingMode: behindWindow
        pythiaGlassMaterial: menu
        glassTintColor: "0x808080"
        glassStyle: regular
        """
        let dict = SimpleYaml.load(hermeticYaml)
        if let theme = theme(from: dict) { return [theme] }
        return []
    }
}