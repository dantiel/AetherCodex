import SwiftUI
import Combine

// MARK: - Editor Display Settings

/// Persisted, observable editor display preferences. Unlike `ThemeSettings`
/// (which is a plain `UserDefaults` facade posting a `Notification`), this is an
/// `ObservableObject` so the SwiftUI chrome re-renders the instant a toggle
/// flips — no manual notification plumbing, one source of truth.
///
/// - `showLineNumbers`: collapse/expand the gutter number column.
/// - `showWrapColumn`: draw the wrap-column guide line.
/// - `wrapColumn`: the character column the guide (and soft wrap) targets.
final class EditorDisplaySettings: ObservableObject {
    static let shared = EditorDisplaySettings()

    @Published var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: Keys.showLineNumbers) }
    }
    @Published var showWrapColumn: Bool {
        didSet { defaults.set(showWrapColumn, forKey: Keys.showWrapColumn) }
    }
    @Published var wrapColumn: Int {
        didSet { defaults.set(wrapColumn, forKey: Keys.wrapColumn) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let showLineNumbers = "EditorDisplaySettings.showLineNumbers"
        static let showWrapColumn = "EditorDisplaySettings.showWrapColumn"
        static let wrapColumn = "EditorDisplaySettings.wrapColumn"
    }

    private init() {
        if defaults.object(forKey: Keys.showLineNumbers) == nil {
            defaults.set(true, forKey: Keys.showLineNumbers)
        }
        if defaults.object(forKey: Keys.showWrapColumn) == nil {
            defaults.set(false, forKey: Keys.showWrapColumn)
        }
        let storedColumn = defaults.integer(forKey: Keys.wrapColumn)
        wrapColumn = storedColumn > 0 ? storedColumn : 80
        showLineNumbers = defaults.bool(forKey: Keys.showLineNumbers)
        showWrapColumn = defaults.bool(forKey: Keys.showWrapColumn)
    }

    /// Presets surfaced in the View → Wrap Column Width menu.
    static let presets: [Int] = [72, 80, 100, 120]
}
