import Foundation

/// Resource bundle accessor for the macOS editor's visual grammar.
///
/// Themes (YAML), Syntax (tmLanguage + tree-sitter queries), and Fonts are the
/// AetherCodex shell's own assets — they live here in the macOS package, not in
/// the shared `AetherOracle/` core (which is pure Ruby + C, no Swift, no UI).
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