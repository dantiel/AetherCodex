import Foundation
import Cocoa

// MARK: - Scope Settings Resolver

/// Cascading settings resolver for `.aether-properties` scope-based configuration.
/// Uses the same INI-like syntax as TextMate's `.tm_properties` but under ÆtherCodex's
/// own filename — session/transient state lives in UserDefaults, leaving `.aether-properties`
/// purely for user-editable editor configuration.
///
/// Resolution order (highest priority first):
/// 1. Project-local `.aether-properties` — scope sections
/// 2. Project-local `.aether-properties` — root section
/// 3. Global `~/.aether-properties` — scope sections
/// 4. Global `~/.aether-properties` — root section
///
/// Scope resolution walks the ancestor chain: `source.ruby.rails` → `source.ruby` → `source` → root.
/// Glob sections are checked for file-path–based resolution before scope sections.
final class ScopeSettings {

    static let shared = ScopeSettings()

    // MARK: - Cached state

    private var globalFile: TMPropertiesFile?
    private var projectFile: TMPropertiesFile?
    private var projectRoot: String?

    /// Predefined variables available in all files.
    private var builtinVariables: [String: String] {
        var vars: [String: String] = [:]
        vars["CWD"] = projectRoot ?? FileManager.default.currentDirectoryPath
        if let root = projectRoot {
            vars["TM_PROJECT_DIRECTORY"] = root
        }
        return vars
    }

    private init() {}

    // MARK: - Loading

    /// Load (or reload) the global `~/.aether-properties`.
    func loadGlobal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.aether-properties"
        globalFile = TMPropertiesParser.parse(fileAt: path)
        if let gf = globalFile {
            print("[ScopeSettings] loaded global: \(path) → \(gf.sections.count) sections, \(gf.variables.count) vars")
        } else {
            print("[ScopeSettings] WARNING: no global .aether-properties at \(path)")
        }
    }

    /// Set the project root directory and load its `.aether-properties` if present.
    /// Pass `nil` to clear the project-level configuration.
    func setProjectRoot(_ path: String?) {
        projectRoot = path
        if let p = path {
            projectFile = TMPropertiesParser.parse(fileAt: "\(p)/.aether-properties")
        } else {
            projectFile = nil
        }
    }

    // MARK: - Scope Resolution

    /// Resolve a setting value for a given TextMate scope (e.g., `"source.ruby"`).
    /// Walks the ancestor scope chain, checking project then global files.
    /// Returns the resolved string (with variables interpolated), or `nil` if unset.
    func resolve(scope: String, key: String) -> String? {
        let scopes = TreeSitterScopeMapper.ancestorScopes(for: scope)

        // 1. Project file — scope sections (most specific first)
        if let pf = projectFile {
            for s in scopes {
                if let v = setting(in: pf, scope: s, key: key) { return v }
            }
            // 2. Project file — root section
            if let v = setting(in: pf, scope: nil, key: key) { return v }
        }

        // 3. Global file — scope sections
        if let gf = globalFile {
            for s in scopes {
                if let v = setting(in: gf, scope: s, key: key) { return v }
            }
            // 4. Global file — root section
            if let v = setting(in: gf, scope: nil, key: key) { return v }
        }

        return nil
    }

    /// Resolve a setting for a file path. Checks glob sections first, then scope sections.
    func resolve(filePath: String, scope: String, key: String) -> String? {
        // 1. Check glob sections in project file
        if let pf = projectFile {
            if let v = globSetting(in: pf, filePath: filePath, key: key) { return v }
        }
        // 2. Check glob sections in global file
        if let gf = globalFile {
            if let v = globSetting(in: gf, filePath: filePath, key: key) { return v }
        }
        // 3. Fall back to scope resolution
        return resolve(scope: scope, key: key)
    }

    /// Check if a glob section in the given file matches and return the setting.
    private func globSetting(in file: TMPropertiesFile, filePath: String, key: String) -> String? {
        for section in file.sections where section.isGlob {
            guard let sel = section.selector else { continue }
            if TMPropertiesParser.matchesGlob(sel, path: filePath) {
                if let val = section.settings[key] {
                    return file.resolveVariables(in: val, extraVars: builtinVariables)
                }
            }
        }
        return nil
    }

    /// Find a setting within a specific scope section of a parsed file.
    private func setting(in file: TMPropertiesFile, scope: String?, key: String) -> String? {
        for section in file.sections {
            guard section.selector == scope, !section.isGlob else { continue }
            if let val = section.settings[key] {
                return file.resolveVariables(in: val, extraVars: builtinVariables)
            }
        }
        return nil
    }

    // MARK: - Typed Convenience Resolvers

    /// Resolve a font from scope settings. Returns `nil` if no scope-specific font configured.
    func resolveFont(scope: String) -> NSFont? {
        guard let fontName = resolve(scope: scope, key: "fontName") else { return nil }
        let sizeStr = resolve(scope: scope, key: "fontSize")
        let size = sizeStr.flatMap(Double.init) ?? ThemeSettings.shared.fontSize
        return NSFont(name: fontName, size: size)
    }

    /// Resolve `fontSize` as a Double.
    func resolveFontSize(scope: String) -> Double? {
        resolve(scope: scope, key: "fontSize").flatMap(Double.init)
    }

    /// Resolve `tabSize` as an Int.
    func resolveTabSize(scope: String) -> Int? {
        resolve(scope: scope, key: "tabSize").flatMap(Int.init)
    }

    /// Resolve `softTabs` as a Bool.
    func resolveSoftTabs(scope: String) -> Bool? {
        guard let v = resolve(scope: scope, key: "softTabs") else { return nil }
        return v == "true" || v == "yes" || v == "1"
    }

    /// Resolve `softWrap` as a Bool.
    func resolveSoftWrap(scope: String) -> Bool? {
        guard let v = resolve(scope: scope, key: "softWrap") else { return nil }
        return v == "true" || v == "yes" || v == "1"
    }

    /// Resolve `showInvisibles` as a Bool.
    func resolveShowInvisibles(scope: String) -> Bool? {
        guard let v = resolve(scope: scope, key: "showInvisibles") else { return nil }
        return v == "true" || v == "yes" || v == "1"
    }

    /// Resolve `spellChecking` as a Bool.
    func resolveSpellChecking(scope: String) -> Bool? {
        guard let v = resolve(scope: scope, key: "spellChecking") else { return nil }
        return v == "true" || v == "yes" || v == "1"
    }

    /// Resolve `theme` — explicit syntax theme name override for this scope.
    /// e.g. `theme = "Solarized Dark"` in `[ source.ruby ]`.
    func resolveThemeName(scope: String) -> String? {
        resolve(scope: scope, key: "theme")
    }

    /// Resolve `appearance` — force light or dark system appearance for this scope.
    /// e.g. `appearance = dark` in `[ source.ruby ]`.
    /// Returns `"dark"`, `"light"`, or `nil`.
    func resolveAppearance(scope: String) -> String? {
        resolve(scope: scope, key: "appearance")
    }
}