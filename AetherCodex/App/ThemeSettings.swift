import Cocoa

// MARK: - Theme Settings

/// Persisted user preferences — font, dark/light theme assignments,
/// graphical overrides. Stored in UserDefaults; posts `.didChangeNotification`.
final class ThemeSettings {
    static let shared = ThemeSettings()

    static let didChangeNotification = Notification.Name("ThemeSettingsDidChange")

    private enum Key: String {
        case fontFamily, fontSize
        case proportionalFontFamily, proportionalFontSize
        case darkThemeName, lightThemeName
        case editorOpacity, textShadow, lineSpacing, glassTint, glassBlurStrength
        case fileBrowserOverlay
        case editorBackgroundOpacity
        case sidebarBackgroundOpacity
        case sidebarGlassBlurStrength
        case highlightCurrentLine
    }

    private let defaults = UserDefaults.standard

    // ── Monospaced Font (code) ──

    var fontFamily: String? {
        get { defaults.string(forKey: Key.fontFamily.rawValue) }
        set { defaults.set(newValue, forKey: Key.fontFamily.rawValue); postChange() }
    }

    var fontSize: Double {
        get { let v = defaults.double(forKey: Key.fontSize.rawValue); return v > 0 ? v : 13.0 }
        set { defaults.set(newValue, forKey: Key.fontSize.rawValue); postChange() }
    }

    var resolvedMonoFont: NSFont {
        if let fam = fontFamily, let f = NSFont(name: fam, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // ── Proportional Font (prose) ──

    var proportionalFontFamily: String? {
        get { defaults.string(forKey: Key.proportionalFontFamily.rawValue) }
        set { defaults.set(newValue, forKey: Key.proportionalFontFamily.rawValue); postChange() }
    }

    var proportionalFontSize: Double {
        get { let v = defaults.double(forKey: Key.proportionalFontSize.rawValue); return v > 0 ? v : 14.0 }
        set { defaults.set(newValue, forKey: Key.proportionalFontSize.rawValue); postChange() }
    }

    var resolvedProportionalFont: NSFont {
        if let fam = proportionalFontFamily, let f = NSFont(name: fam, size: proportionalFontSize) { return f }
        return NSFont.systemFont(ofSize: proportionalFontSize)
    }

    /// Resolve font for the given file type.
    func resolvedFont(for fileType: FileType) -> NSFont {
        fileType.isCode ? resolvedMonoFont : resolvedProportionalFont
    }

    /// Legacy alias — code (monospaced) font.
    var resolvedFont: NSFont { resolvedMonoFont }

    // ── Dark / Light Theme Picks ──

    var darkThemeName: String {
        get { defaults.string(forKey: Key.darkThemeName.rawValue) ?? "Aethernaut" }
        set { defaults.set(newValue, forKey: Key.darkThemeName.rawValue); postChange() }
    }

    var lightThemeName: String {
        get { defaults.string(forKey: Key.lightThemeName.rawValue) ?? "AetherLight" }
        set { defaults.set(newValue, forKey: Key.lightThemeName.rawValue); postChange() }
    }

    var activeThemeName: String {
        effectiveAppearanceIsDark ? darkThemeName : lightThemeName
    }

    func themeNames(for kind: ThemeKind) -> [String] {
        ThemeRegistry.shared.themes.filter { $0.kind == kind }.map { $0.name }
    }

    /// All unique tags across all themes, sorted.
    var allTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for t in ThemeRegistry.shared.themes {
            for tag in t.tags {
                if seen.insert(tag).inserted { result.append(tag) }
            }
        }
        return result.sorted()
    }

    /// Themes matching a specific tag, or all if tag is nil.
    func themes(tagged tag: String) -> [SyntaxTheme] {
        guard !tag.isEmpty else { return ThemeRegistry.shared.themes }
        return ThemeRegistry.shared.themes.filter { $0.tags.contains(tag) }
    }

    // ── Graphical Overrides ──
    /// nil = use the theme's default. Set to override.

    var editorOpacityOverride: Double? {
        get {
            guard defaults.object(forKey: Key.editorOpacity.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.editorOpacity.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.editorOpacity.rawValue) }
            else { defaults.removeObject(forKey: Key.editorOpacity.rawValue) }
            postChange()
        }
    }

    var textShadowOverride: Double? {
        get {
            guard defaults.object(forKey: Key.textShadow.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.textShadow.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.textShadow.rawValue) }
            else { defaults.removeObject(forKey: Key.textShadow.rawValue) }
            postChange()
        }
    }

    var lineSpacingOverride: Double? {
        get {
            guard defaults.object(forKey: Key.lineSpacing.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.lineSpacing.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.lineSpacing.rawValue) }
            else { defaults.removeObject(forKey: Key.lineSpacing.rawValue) }
            postChange()
        }
    }

    /// Resolved opacity (override → theme default).
    func resolvedEditorOpacity(for theme: SyntaxTheme) -> CGFloat {
        if let v = editorOpacityOverride { return CGFloat(v) }
        return theme.editorBackgroundOpacity
    }

    func resolvedTextShadow(for theme: SyntaxTheme) -> CGFloat {
        if let v = textShadowOverride { return CGFloat(v) }
        return theme.textShadowStrength
    }

    func resolvedLineSpacing(for theme: SyntaxTheme) -> CGFloat {
        if let v = lineSpacingOverride { return CGFloat(v) }
        return theme.lineSpacing
    }

    // ── Glass Tint ──

    var glassTintOverride: Double? {
        get {
            guard defaults.object(forKey: Key.glassTint.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.glassTint.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.glassTint.rawValue) }
            else { defaults.removeObject(forKey: Key.glassTint.rawValue) }
            postChange()
        }
    }

    /// Resolved glass tint (override → theme default). 0.0 = clear glass, 1.0 = fully tinted.
    func resolvedGlassTint(for theme: SyntaxTheme) -> CGFloat {
        if let v = glassTintOverride { return CGFloat(v) }
        return theme.glassTint
    }

    // ── Glass Blur Strength ──

    var glassBlurStrengthOverride: Double? {
        get {
            guard defaults.object(forKey: Key.glassBlurStrength.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.glassBlurStrength.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.glassBlurStrength.rawValue) }
            else { defaults.removeObject(forKey: Key.glassBlurStrength.rawValue) }
            postChange()
        }
    }

    /// Resolved glass blur strength (override → theme default). 0.0 = clear, 1.0 = maximum blur.
    func resolvedGlassBlurStrength(for theme: SyntaxTheme) -> CGFloat {
        if let v = glassBlurStrengthOverride { return CGFloat(v) }
        return theme.glassBlurStrength
    }

    // ── Editor Background Transparency ──

    var editorBackgroundOpacityOverride: Double? {
        get {
            guard defaults.object(forKey: Key.editorBackgroundOpacity.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.editorBackgroundOpacity.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.editorBackgroundOpacity.rawValue) }
            else { defaults.removeObject(forKey: Key.editorBackgroundOpacity.rawValue) }
            postChange()
        }
    }

    /// Resolved editor background opacity (override → theme default). 0.0 = fully transparent, 1.0 = opaque.
    func resolvedEditorBackgroundOpacity(for theme: SyntaxTheme) -> CGFloat {
        if let v = editorBackgroundOpacityOverride { return CGFloat(v) }
        return theme.editorBackgroundOpacity
    }

    // ── Sidebar Background Transparency ──

    var sidebarBackgroundOpacityOverride: Double? {
        get {
            guard defaults.object(forKey: Key.sidebarBackgroundOpacity.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.sidebarBackgroundOpacity.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.sidebarBackgroundOpacity.rawValue) }
            else { defaults.removeObject(forKey: Key.sidebarBackgroundOpacity.rawValue) }
            postChange()
        }
    }

    /// Resolved sidebar background opacity (override → theme default → editor default).
    func resolvedSidebarBackgroundOpacity(for theme: SyntaxTheme) -> CGFloat {
        if let v = sidebarBackgroundOpacityOverride { return CGFloat(v) }
        return theme.sidebarBackgroundOpacity ?? resolvedEditorBackgroundOpacity(for: theme)
    }

    // ── Sidebar Glass Blur Strength ──

    var sidebarGlassBlurStrengthOverride: Double? {
        get {
            guard defaults.object(forKey: Key.sidebarGlassBlurStrength.rawValue) != nil
            else { return nil }
            return defaults.double(forKey: Key.sidebarGlassBlurStrength.rawValue)
        }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.sidebarGlassBlurStrength.rawValue) }
            else { defaults.removeObject(forKey: Key.sidebarGlassBlurStrength.rawValue) }
            postChange()
        }
    }

    /// Resolved sidebar glass blur strength (override → theme). 0.0 = clear, 1.0 = max blur.
    func resolvedSidebarGlassBlurStrength(for theme: SyntaxTheme) -> CGFloat {
        if let v = sidebarGlassBlurStrengthOverride { return CGFloat(v) }
        return theme.glassBlurStrength
    }

    // ── Word Wrap ──
    // Per-window runtime toggle (EditorViewController.wordWrapOverride)
    // overrides the .aether-properties `softWrap` key. No global/user-defaults
    // setting needed — config lives in .aether-properties, session state in the editor.

    // ── File Browser ──

    var fileBrowserOverlay: Bool {
        get { defaults.bool(forKey: Key.fileBrowserOverlay.rawValue) }
        set { defaults.set(newValue, forKey: Key.fileBrowserOverlay.rawValue); postChange() }
    }

    // ── Font Lists ──

    var availableMonoFamilies: [String] {
        var names = Set<String>()
        names.insert(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName ?? "Menlo")
        for fam in ["Menlo", "Monaco", "SF Mono", "JetBrains Mono", "Fira Code",
                     "Source Code Pro", "Cascadia Code", "IBM Plex Mono", "Consolas"] {
            if NSFont(name: fam, size: 13) != nil { names.insert(fam) }
        }
        return names.sorted()
    }

    var availableProportionalFamilies: [String] {
        var names = Set<String>()
        for fam in ["Helvetica Neue", "SF Pro Text", "New York", "Georgia", "Palatino",
                     "Avenir Next", "Hoefler Text", "Charter", "Times New Roman"] {
            if NSFont(name: fam, size: 14) != nil { names.insert(fam) }
        }
        return names.sorted()
    }

    // ── Current Line Highlight ──

    /// When true, the current line is highlighted in gutter and editor.
    var highlightCurrentLine: Bool {
        get {
            if defaults.object(forKey: Key.highlightCurrentLine.rawValue) == nil { return true }
            return defaults.bool(forKey: Key.highlightCurrentLine.rawValue)
        }
        set { defaults.set(newValue, forKey: Key.highlightCurrentLine.rawValue); postChange() }
    }

    /// Current-line highlight color from the active theme.
    var lineHighlightColor: NSColor {
        return ThemeRegistry.shared.current.lineHighlight
    }

    // MARK: - Internal

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private var effectiveAppearanceIsDark: Bool {
        let name = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua
    }

    private init() {}
}

// MARK: - File Type Detection

enum FileType {
    case swift, ruby, python, javascript, typescript, c, cpp, rust, go, java,
         kotlin, shell, yaml, json, xml, html, css, markdown, text, unknown

    init(ext: String) {
        switch ext.lowercased() {
        case "swift":          self = .swift
        case "rb":            self = .ruby
        case "py":            self = .python
        case "js":            self = .javascript
        case "ts", "tsx":     self = .typescript
        case "c":             self = .c
        case "cpp", "cc", "cxx", "hpp": self = .cpp
        case "rs":            self = .rust
        case "go":            self = .go
        case "java", "kt":    self = .java
        case "sh", "bash", "zsh": self = .shell
        case "yaml", "yml":   self = .yaml
        case "json":          self = .json
        case "xml", "plist":  self = .xml
        case "html", "htm":   self = .html
        case "css", "scss", "less": self = .css
        case "md", "mkdn", "markdown": self = .markdown
        case "txt", "text", "rdoc":  self = .text
        default:              self = .unknown
        }
    }

    /// True for code files → monospaced font.
    var isCode: Bool {
        switch self {
        case .markdown, .text: return false
        default:               return true
        }
    }

    /// Human-readable display name for status bar etc.
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .ruby: return "Ruby"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .c: return "C"
        case .cpp: return "C++"
        case .rust: return "Rust"
        case .go: return "Go"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .css: return "CSS"
        case .markdown: return "Markdown"
        case .text: return "Plain Text"
        case .unknown: return "Plain Text"
        }
    }
}