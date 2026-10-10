import Foundation

// MARK: - General Settings
//
// App-wide preferences that aren't appearance/theme concerns — currently the
// "new window / new file" conjuration contract. Stored in UserDefaults and
// surfaced as an ObservableObject so SwiftUI forms bind directly, while
// `EditorViewController` reads the same singleton when a window is born.

enum NewFileMode: String, CaseIterable, Identifiable {
    case blank
    case flash
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blank: return "Blank file"
        case .flash: return "Flash code poetry"
        }
    }
}

enum NewFileLanguageMode: String, CaseIterable, Identifiable {
    case plainText
    case random
    case specific
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plainText: return "Plain text"
        case .random: return "Random"
        case .specific: return "Specific language"
        }
    }
}

final class GeneralSettings: ObservableObject {
    static let shared = GeneralSettings()

    private enum Key: String {
        case newFileMode, newFileLanguageMode, newFileLanguageName, alwaysShowTabBar, gitExternalEditor
    }

    /// Languages offered for the "specific language" choice — kept in sync with
    /// FlashAetherConjurer's pool (swift/rb/py/js/sh).
    static let knownLanguages: [(id: String, name: String)] = [
        ("swift", "Swift"), ("rb", "Ruby"), ("py", "Python"),
        ("js", "JavaScript"), ("sh", "Bash"),
    ]

    @Published var newFileMode: NewFileMode {
        didSet { defaults.set(newFileMode.rawValue, forKey: Key.newFileMode.rawValue) }
    }
    @Published var newFileLanguageMode: NewFileLanguageMode {
        didSet { defaults.set(newFileLanguageMode.rawValue, forKey: Key.newFileLanguageMode.rawValue) }
    }
    @Published var newFileLanguageName: String {
        didSet { defaults.set(newFileLanguageName, forKey: Key.newFileLanguageName.rawValue) }
    }
    /// Keep the editor tab strip visible even with a single open document.
    @Published var alwaysShowTabBar: Bool {
        didSet { defaults.set(alwaysShowTabBar, forKey: Key.alwaysShowTabBar.rawValue) }
    }
    /// External Git editor command for the diff "open in external editor" action.
    /// Empty string = auto-detect (`git config core.editor`, then env vars).
    @Published var gitExternalEditor: String {
        didSet { defaults.set(gitExternalEditor, forKey: Key.gitExternalEditor.rawValue) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        newFileMode = NewFileMode(rawValue: defaults.string(forKey: Key.newFileMode.rawValue) ?? "") ?? .flash
        newFileLanguageMode = NewFileLanguageMode(rawValue: defaults.string(forKey: Key.newFileLanguageMode.rawValue) ?? "") ?? .random
        newFileLanguageName = defaults.string(forKey: Key.newFileLanguageName.rawValue) ?? "swift"
        alwaysShowTabBar = defaults.bool(forKey: Key.alwaysShowTabBar.rawValue)
        gitExternalEditor = defaults.string(forKey: Key.gitExternalEditor.rawValue) ?? ""
    }

    /// Resolve the language a fresh flash conjuration should speak. Safe to call
    /// from any thread — `pickLanguage` performs its own capped, read-only scan.
    func resolvedLanguage(root: String?) -> String {
        switch newFileLanguageMode {
        case .plainText: return "text"
        case .random: return FlashAetherConjurer.pickLanguage(root: root)
        case .specific: return newFileLanguageName.isEmpty ? "swift" : newFileLanguageName
        }
    }
}