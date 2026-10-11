import Cocoa
import CoreText
import AetherOracleResources

// MARK: - Bundled typeface registry

/// Registers the typefaces bundled with AetherCodex so Syne and Syne Mono are
/// first-class citizens — present on every machine regardless of whether the
/// user has them installed system-wide.
///
/// SwiftPM *flattens* processed resource bundles (there is no `Fonts/`
/// subdirectory at runtime), so the locator checks every surface the fonts may
/// land on: the SPM module bundle root, a `Fonts/` subdirectory of the module
/// bundle, the app bundle's `Resources/Fonts`, the app bundle root, and finally
/// the source-tree path used during development.
enum FontBundler {
    static func registerAll() {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let root = AetherOracleResources.bundle.resourceURL {
            candidates.append(root)
            candidates.append(root.appendingPathComponent("Fonts"))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Fonts"))
            candidates.append(res)
        }
        candidates.append(URL(fileURLWithPath: "AetherOracle/resources/Fonts"))

        var fonts: [URL] = []
        var seen = Set<String>()
        for dir in candidates {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries {
                let ext = url.pathExtension.lowercased()
                guard ext == "ttf" || ext == "otf" else { continue }
                if seen.insert(url.lastPathComponent).inserted { fonts.append(url) }
            }
        }

        guard !fonts.isEmpty else { return }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true) { errors, _ in
            if CFArrayGetCount(errors) > 0 {
                print("[FontBundler] registration issue: \(errors)")
            } else {
                print("[FontBundler] registered \(fonts.count) bundled typefaces")
            }
            return true
        }
    }
}