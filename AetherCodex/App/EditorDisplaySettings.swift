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
    /// Mirrored code font size (pt). Drives the gutter recompute + the HUD —
    /// `ThemeSettings` is a plain UserDefaults facade, so this observable is the
    /// bridge that re-renders the SwiftUI chrome when ⌘+/⌘- changes the size.
    @Published var fontSize: Double = 13
    /// Bumps only when `fontSize` actually changes; the font-size HUD listens here.
    @Published var fontSizeChangeToken: Int = 0

    /// Current code font size as a percentage of the 13pt default (⌘0 → 100%).
    var fontSizePercent: Int {
        Int((fontSize / 13.0 * 100).rounded())
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
        fontSize = ThemeSettings.shared.fontSize

        // Mirror `ThemeSettings` changes into this observable. Any theme change
        // re-solves the gutter (width + line pitch derive from the resolved base
        // font); a font-*size* change additionally bumps the HUD token.
        NotificationCenter.default.addObserver(
            forName: ThemeSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let newSize = ThemeSettings.shared.fontSize
            if newSize != self.fontSize {
                self.fontSize = newSize
                self.fontSizeChangeToken += 1
            }
        }
    }

    /// Presets surfaced in the View → Wrap Column Width menu.
    static let presets: [Int] = [72, 80, 100, 120]
}