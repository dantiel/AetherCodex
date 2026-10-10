import Cocoa

// MARK: - Token Style

/// Visual attributes for a token — color, background, typographic traits,
/// and optional per-scope font overrides (used by themes like Argonaut
/// for headings, tasks, etc.).
struct TokenStyle {
    /// nil = inherit foreground from cascade parent (TextMate convention).
    let foreground: NSColor?
    let background: NSColor?
    /// nil = inherit from cascade parent; true/false = explicit override.
    let isBold: Bool?
    /// nil = inherit from cascade parent; true/false = explicit override.
    let isItalic: Bool?
    /// nil = inherit from cascade parent; true/false = explicit override.
    let isUnderline: Bool?
    /// nil = inherit from cascade parent; true/false = explicit override.
    let isStrikethrough: Bool?
    /// Optional per-scope font name override (nil = use editor default).
    let fontName: String?
    /// Optional per-scope font size override (nil = use editor default).
    let fontSize: CGFloat?

    init(_ fg: NSColor? = nil, bg: NSColor? = nil,
         bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil,
         strikethrough: Bool? = nil,
         fontName: String? = nil, fontSize: CGFloat? = nil) {
        self.foreground = fg
        self.background = bg
        self.isBold = bold
        self.isItalic = italic
        self.isUnderline = underline
        self.isStrikethrough = strikethrough
        self.fontName = fontName
        self.fontSize = fontSize
    }

    /// Convenience: color-only, no traits. Foreground is explicit (non-nil).
    static func color(_ c: NSColor) -> TokenStyle { TokenStyle(c) }
}

// MARK: - Token Scopes

/// Granular token scopes — maps to TextMate-style scope names.
/// `TokenScope` only defines **categories**; the tokenizer decides resolution.
/// TextMate-style dot-separated scope names with prefix-based cascade.
/// Resolution for `markup.heading.1` walks: `markup.heading.1` → `markup.heading` → `markup`.
enum TokenScope: String, CaseIterable {
    // ── Core (universal) ──
    case keyword
    case keywordType          = "keyword.type"
    case `operator`
    case string
    case stringEscape         = "string.escape"
    case constantCharacterEscape = "constant.character.escape"
    case number               = "constant.numeric"
    case comment
    case type                 // class/struct/enum definitions
    case typeSupport          = "support.type"
    case function
    case functionSupport      = "support.function"
    case variable
    case variableLanguage     = "variable.language"
    case variableInstance     = "variable.instance"
    case variableClass        = "variable.class"
    case variableGlobal       = "variable.global"
    case constant
    case constantSymbol       = "constant.symbol"
    case constantSupport      = "support.constant"
    case property
    case punctuation
    case tag                  // HTML/XML tag names
    case attribute            // HTML/XML attribute names
    case heading              = "markup.heading"
    case heading1             = "markup.heading.1"
    case heading2             = "markup.heading.2"
    case heading3             = "markup.heading.3"
    case heading4             = "markup.heading.4"
    case heading5             = "markup.heading.5"
    case heading6             = "markup.heading.6"
    case link                 = "markup.link"
    case linkURL              = "markup.link.url"
    case emphasis             = "markup.italic"
    case strong               = "markup.bold"
    case strikethrough        = "markup.strikethrough"
    case blockquote           = "markup.quote"
    case thematicBreak        = "markup.rule"
    case codeBlock            = "markup.code.block"
    case checkedListItem      = "markup.list.checked"
    case markup               = "markup"
    case inlineCode           = "markup.code.inline"
    case preprocessor
    case invalid
    case plain

    // ── Extended: entity names (TextMate/tmTheme origin) ──
    case entityNameClass      = "entity.name.class"
    case entityNameFunction   = "entity.name.function"
    case entityNameTag        = "entity.name.tag"
    case entityNameType         = "entity.name.type"
    case entityNameTypeNamespace = "entity.name.type.namespace"
    case entityOtherInheritedClass = "entity.other.inherited-class"
    case entityOtherAttributeName  = "entity.other.attribute-name"
    case entityOtherTagbraces      = "entity.other.tagbraces"
    case entityOtherArgument       = "entity.other.argument"

    // ── Extended: storage ──
    case storage
    case storageType          = "storage.type"

    // ── Extended: variable sub-scopes ──
    case variableParameter    = "variable.parameter"
    case variableFunction     = "variable.function"
    case variableOther        = "variable.other"

    // ── Extended: constant sub-scopes ──
    case constantLanguage     = "constant.language"
    case constantCharacter    = "constant.character"
    case constantOther        = "constant.other"

    // ── Extended: support sub-scopes ──
    case supportClass         = "support.class"
    case supportOtherVariable = "support.other.variable"
    case supportOtherNamespace = "support.other.namespace"

    // ── Extended: CSS-specific ──
    case entityOtherAttributeNameId    = "entity.other.attribute-name.id"
    case entityOtherAttributeNameClass = "entity.other.attribute-name.class"
    case entityOtherAttributeNamePseudoclass = "entity.other.attribute-name.pseudo-class"
    case supportFunctionMisc           = "support.function.misc"
    case supportConstantPropertyValue  = "support.constant.property-value"
    case supportConstantFontName       = "support.constant.font-name"

    // ── Extended: markup sub-scopes ──
    case markupRaw            = "markup.raw"
    case markupOther          = "markup.other"
    case meta                 = "meta"
    case metaClass            = "meta.class"
    case metaFunction         = "meta.function"
    case metaEmbedded         = "meta.embedded"
}

// MARK: - Theme Protocol

/// A complete syntax theme — scopes, editor chrome, graphical effects, and trait support.
protocol SyntaxTheme {
    var name: String { get }
    var appearance: ThemeAppearance { get }
    /// Free-form tags for browsing / filtering — e.g. ["vibrant", "dark", "ink"].
    /// Themes can be grouped by any tag; the theme picker shows tag chips.
    var tags: [String] { get }
    /// Semantic class for categorization — e.g. "theme.Vibrant Dark", "theme.Vibrant Light".
    /// Used by the theme picker for dark/light grouping and family identification.
    var themeClass: String? { get }

    /// Per-scope visual style (TokenScope enum keyed).
    func style(for scope: TokenScope) -> TokenStyle

    /// Per-scope visual style by raw TextMate scope string.
    /// Supports arbitrary scope names like "entity.name.class" beyond
    /// the TokenScope enum. Falls back to prefix-based cascade.
    func style(forScope scopeName: String) -> TokenStyle

    // ── Editor chrome ──
    var editorBackground: NSColor { get }
    var editorForeground: NSColor { get }
    var caretColor: NSColor { get }
    var selectionColor: NSColor { get }
    var lineHighlight: NSColor { get }
    /// Vertical separator between ruler and text area.
    var rulerSeparator: NSColor { get }
    /// Border drawn around the current-line highlight rect.
    var lineHighlightBorder: NSColor { get }
    /// Translucent background drawn behind line numbers in the ruler.
    var rulerBackground: NSColor { get }
    var rulerForeground: NSColor { get }
    /// Absolute point size for gutter line numbers (nil = derive from editor font).
    var rulerFontSize: CGFloat? { get }
    var sidebarAccent: NSColor { get }
    var sidebarForeground: NSColor { get }
    /// Gutter selection background — drawn behind selected line numbers.
    var gutterSelectionBackground: NSColor { get }
    /// Gutter selection foreground — line number text color when selected.
    var gutterSelectionForeground: NSColor { get }
    /// Gutter selection border — top/bottom 1px lines around selected region.
    var gutterSelectionBorder: NSColor { get }

    // ── Graphical effects (theme-controlled) ──
    /// 0.0 = fully transparent editor surface, 1.0 = opaque theme color.
    var editorBackgroundOpacity: CGFloat { get }
    /// Sidebar pane background (nil = use editorBackground). Usually lighter
    /// for dark themes so the sidebar doesn't become a black void.
    var sidebarBackground: NSColor? { get }
    /// Sidebar pane opacity (nil = use editorBackgroundOpacity).
    var sidebarBackgroundOpacity: CGFloat? { get }
    /// 0.0 = no text shadow, 1.0 = deep glow.
    var textShadowStrength: CGFloat { get }
    /// Extra leading between lines (pts).
    var lineSpacing: CGFloat { get }
    // ── Liquid Glass (macOS 26+) ──
    /// Tint color for NSGlassEffectView sidebar and Pythia panes.
    var glassTintColor: NSColor { get }
    /// Glass style: .regular (standard) or .clear (transparent).
    var glassStyle: NSGlassEffectView.Style { get }
    /// Glass tint: 0.0 = no tint (clear glass), 1.0 = fully tinted (opaque glass).
    var glassTint: CGFloat { get }
    /// Glass blur density: 0.0 = clearest (thin blur), 1.0 = heaviest blur.
    var glassBlurStrength: CGFloat { get }
    /// Sidebar glass material name (e.g. "sidebar", "menu", "tooltip").
    var sidebarGlassMaterialName: String? { get }
    /// The Pythia oracle chamber palette — derived from the chrome when not
    /// explicitly declared via a first-class `pythia:` block.
    var pythia: PythiaPalette { get }

    // ── Deprecated pre-Liquid-Glass materials (kept for compatibility) ──
    @available(macOS, deprecated: 26.0, message: "Liquid Glass uses glassTintColor")
    var rootBlurMaterial: NSVisualEffectView.Material { get }
    @available(macOS, deprecated: 26.0, message: "Liquid Glass uses glassTintColor")
    var rootBlendingMode: NSVisualEffectView.BlendingMode { get }
    @available(macOS, deprecated: 26.0, message: "Liquid Glass uses glassTintColor")
    var pythiaGlassMaterial: NSVisualEffectView.Material { get }
}

extension SyntaxTheme {
    var rulerForeground: NSColor { editorForeground.withAlphaComponent(0.65) }
    var rulerFontSize: CGFloat? { nil }
    var sidebarAccent: NSColor { selectionColor.withAlphaComponent(1) }
    var sidebarForeground: NSColor { editorForeground }
}

enum ThemeAppearance: String, CaseIterable {
    case dark
    case light
}

// MARK: - Theme Defaults

extension SyntaxTheme {
    /// Human-readable name derived from the raw identifier. Imported themes
    /// carry lower-dash-case ids (`base16-atelier-dune-dark`); this yields a
    /// proper title (`Base16 Atelier Dune Dark`) while leaving already-named
    /// CamelCase / capitalized signatures (AetherNight, Abyss) untouched.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // Separators present → split into words and title-case each.
        if trimmed.contains(where: { $0 == "-" || $0 == "_" }) {
            return trimmed
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { word -> String in
                    let s = String(word)
                    guard let first = s.first else { return s }
                    return String(first).uppercased() + s.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
        // No separators → capitalize first letter, preserve interior casing
        // (so "monokai" → "Monokai", but "AetherNight" stays "AetherNight").
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    // ── Tags — empty by default ──
    var tags: [String] { [] }
    // ── Semantic class — nil by default ──
    var themeClass: String? { nil }
    // ── Chrome defaults (dark) ──
    var editorBackground: NSColor { NSColor(white: 0.08, alpha: 1.0) }
    var editorForeground: NSColor { NSColor(white: 0.70, alpha: 1.0) }
    var caretColor: NSColor { .white }
    var selectionColor: NSColor { NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 1.0) }
    var lineHighlight: NSColor { NSColor(white: 0.12, alpha: 1.0) }
    var rulerSeparator: NSColor { NSColor(white: 0.25, alpha: 0.6) }
    var lineHighlightBorder: NSColor { NSColor(white: 0.30, alpha: 0.5) }
    var rulerBackground: NSColor { NSColor(white: 0.10, alpha: 0.45) }
    var gutterSelectionBackground: NSColor { NSColor(red: 0.00, green: 0.18, blue: 0.33, alpha: 0.4) }
    var gutterSelectionForeground: NSColor { NSColor(white: 0.85, alpha: 1.0) }
    var gutterSelectionBorder: NSColor { NSColor(red: 0.00, green: 0.22, blue: 0.44, alpha: 0.8) }

    // ── Graphical defaults ──
    var editorBackgroundOpacity: CGFloat { 0.0 }
    var sidebarBackground: NSColor? { nil }
    var sidebarBackgroundOpacity: CGFloat? { nil }
    var textShadowStrength: CGFloat { 0.6 }
    var lineSpacing: CGFloat { 4.0 }
    /// Glass tint — subtle violet for dark themes, golden for light.
    var glassTintColor: NSColor { NSColor(red: 0.45, green: 0.35, blue: 0.60, alpha: 0.25) }
    var glassStyle: NSGlassEffectView.Style { .regular }
    var glassTint: CGFloat { 0.70 }
    var glassBlurStrength: CGFloat { 0.50 }
    var sidebarGlassMaterialName: String? { nil }
    var rootBlurMaterial: NSVisualEffectView.Material { .fullScreenUI }
    var rootBlendingMode: NSVisualEffectView.BlendingMode { .behindWindow }
    var pythiaGlassMaterial: NSVisualEffectView.Material { .menu }

    // ── Pythia palette (derived) ──
    var pythia: PythiaPalette {
        PythiaPalette.derive(
            background: sidebarBackground ?? editorBackground,
            foreground: editorForeground,
            accent: sidebarAccent,
            appearance: appearance,
            glassTint: glassTint,
            glassMaterialName: sidebarGlassMaterialName
        )
    }
}

// ────────────────────────────────────────────────────────────
// MARK: - Theme Registry
// ────────────────────────────────────────────────────────────

final class ThemeRegistry {
    static let shared = ThemeRegistry()

    /// Themes loaded from Resources/Themes/*.yml at startup.
    let themes: [SyntaxTheme]

    var current: SyntaxTheme {
        guard !themes.isEmpty else {
            return ThemeLoader.builtInThemes().first ?? ThemeLoader.fallbackTheme()
        }
        let idx = themes.indices.contains(activeIndex) ? activeIndex : 0
        return themes[idx]
    }

    private(set) var activeIndex: Int = 0 {
        didSet {
            guard activeIndex != oldValue else { return }
            onChange?()
        }
    }

    var activeName: String { current.name }

    /// Fires when theme changes — editors re-highlight and reconfigure chrome.
    var onChange: (() -> Void)?

    private var appearanceObserver: NSKeyValueObservation?

    private init() {
        // Load all themes from Resources/Themes/*.yml
        let loaded = ThemeLoader.loadAll()
        themes = loaded.isEmpty ? ThemeLoader.builtInThemes() : loaded

        // Start with the right theme for the current appearance
        activate(named: ThemeSettings.shared.activeThemeName)

        // Observe system appearance changes → swap dark/light theme
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.applyAppearanceTheme()
        }
    }

    func activate(index: Int) {
        guard themes.indices.contains(index) else { return }
        activeIndex = index
        persistCurrent()
    }

    func activate(named name: String) {
        guard let idx = themes.firstIndex(where: { $0.name == name }) else { return }
        activeIndex = idx
        persistCurrent()
    }

    func next() {
        activeIndex = (activeIndex + 1) % themes.count
        persistCurrent()
    }

    func previous() {
        activeIndex = (activeIndex - 1 + themes.count) % themes.count
        persistCurrent()
    }

    // MARK: - Appearance Switching

    private func applyAppearanceTheme() {
        let name = ThemeSettings.shared.activeThemeName
        guard current.name != name else { return }
        activate(named: name)
    }

    private func persistCurrent() {
        let theme = current
        switch theme.appearance {
        case .dark:  ThemeSettings.shared.darkThemeName = theme.name
        case .light: ThemeSettings.shared.lightThemeName = theme.name
        }
    }
}