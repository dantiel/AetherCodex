import Foundation

/// Resource bundle accessor for the macOS editor's visual grammar.
///
/// Themes (YAML), Syntax (tmLanguage + tree-sitter queries), and Fonts are the
/// shared AetherOracle core's data — they live in `AetherOracle/resources/`,
/// consumed by both the Ruby chamber (ÆtherTheme) and every native shell. This
/// enum only wraps them into a `Bundle.module` for the macOS package.
public enum AetherOracleResources {
    /// The resource bundle for this resource-only target.
    ///
    /// `Bundle.module`'s generated accessor only probes the `.app` *root* and
    /// the build directory — never the standard `Contents/Resources/` slot.
    /// When packaged, the bundle lives in `Contents/Resources/`, so resolve
    /// that location first. This keeps the `.app` root free of stray bundles,
    /// which is exactly what lets `codesign` seal it for a release DMG.
    public static var bundle: Bundle {
        if let resourceURL = Bundle.main.resourceURL {
            let packaged = resourceURL.appendingPathComponent("AetherCodex_AetherOracleResources.bundle")
            if let found = Bundle(path: packaged.path) { return found }
        }
        let rooted = Bundle.main.bundleURL.appendingPathComponent("AetherCodex_AetherOracleResources.bundle")
        if let found = Bundle(path: rooted.path) { return found }
        return .module
    }
}