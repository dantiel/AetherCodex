import Cocoa

// MARK: - Session State

/// Persisted session data stored in UserDefaults.
/// Restores last project, file, window geometry, and UI state on launch.
/// (Previously stored in ~/.aether-properties JSON; migrated on first launch.)
struct SessionData {
    var lastProjectFolder: String?
    var lastOpenFile: String?
    var windowFrame: WindowFrame?
    var sidebarWidth: Double?
    var pythiaWidth: Double?
    var fileBrowserOverlay: Bool = false
    var selectedSidebarTab: String?
    var activeThemeName: String?

    struct WindowFrame {
        let x: Double; let y: Double; let width: Double; let height: Double

        static let defaultFrame = WindowFrame(x: 100, y: 100, width: 1400, height: 900)
    }
}

/// Thin proxy over UserDefaults — session state is machine-managed, not user-editable.
/// (Scope-based editor settings live in ~/.aether-properties INI files.)
/// Serializable window descriptor for multi-window session persistence.
struct WindowState: Codable {
    var frame: FrameDesc?
    var lastOpenFile: String?
    var lastProjectFolder: String?
    var sidebarWidth: Double?
    var pythiaWidth: Double?

    struct FrameDesc: Codable {
        let x: Double; let y: Double; let width: Double; let height: Double
    }
}

final class SessionState {
    static let shared = SessionState()

    private let defaults = UserDefaults.standard

    private init() {
        migrateLegacyJSONIfPresent()
    }

    // MARK: - Multi-window persistence

    var windowStates: [WindowState] {
        get {
            guard let data = defaults.data(forKey: "session.windows"),
                  let s = try? JSONDecoder().decode([WindowState].self, from: data)
            else { return [] }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "session.windows")
            } else {
                defaults.removeObject(forKey: "session.windows")
            }
        }
    }

    // MARK: - Single-window accessors (UserDefaults-backed, legacy compat)

    var lastProjectFolder: String? {
        get { defaults.string(forKey: "session.lastProjectFolder") }
        set { defaults.set(newValue, forKey: "session.lastProjectFolder") }
    }

    var lastOpenFile: String? {
        get { defaults.string(forKey: "session.lastOpenFile") }
        set { defaults.set(newValue, forKey: "session.lastOpenFile") }
    }

    var windowFrame: SessionData.WindowFrame? {
        get {
            guard let dict = defaults.dictionary(forKey: "session.windowFrame"),
                  let x = dict["x"] as? Double, let y = dict["y"] as? Double,
                  let w = dict["w"] as? Double, let h = dict["h"] as? Double
            else { return nil }
            return SessionData.WindowFrame(x: x, y: y, width: w, height: h)
        }
        set {
            if let f = newValue {
                defaults.set(["x": f.x, "y": f.y, "w": f.width, "h": f.height],
                             forKey: "session.windowFrame")
            } else {
                defaults.removeObject(forKey: "session.windowFrame")
            }
        }
    }

    var sidebarWidth: Double? {
        get {
            let v = defaults.double(forKey: "session.sidebarWidth")
            return v > 0 ? v : nil
        }
        set {
            if let v = newValue { defaults.set(v, forKey: "session.sidebarWidth") }
            else { defaults.removeObject(forKey: "session.sidebarWidth") }
        }
    }

    var pythiaWidth: Double? {
        get {
            let v = defaults.double(forKey: "session.pythiaWidth")
            return v > 0 ? v : nil
        }
        set {
            if let v = newValue { defaults.set(v, forKey: "session.pythiaWidth") }
            else { defaults.removeObject(forKey: "session.pythiaWidth") }
        }
    }

    var fileBrowserOverlay: Bool {
        get { defaults.bool(forKey: "session.fileBrowserOverlay") }
        set { defaults.set(newValue, forKey: "session.fileBrowserOverlay") }
    }

    var selectedSidebarTab: String? {
        get { defaults.string(forKey: "session.selectedSidebarTab") }
        set { defaults.set(newValue, forKey: "session.selectedSidebarTab") }
    }

    var activeThemeName: String? {
        get { defaults.string(forKey: "session.activeThemeName") }
        set { defaults.set(newValue, forKey: "session.activeThemeName") }
    }

    /// No-op kept for API compatibility — UserDefaults syncs automatically.
    func flush() {
        defaults.synchronize()
    }

    // MARK: - Migration

    /// One-time: if old ~/.aether-properties JSON exists, lift values into UserDefaults
    /// and remove the file. The filename is now used for scope-based editor settings.
    private func migrateLegacyJSONIfPresent() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyURL = home.appendingPathComponent(".aether-properties")

        guard let data = try? Data(contentsOf: legacyURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Only migrate if the file is JSON (not INI). Fast sniff: first non-ws char is '{'.
        if let first = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).first,
           first != "{" {
            return // Already an INI file — don't touch it
        }

        // Lift known keys into UserDefaults
        if let v = json["lastProjectFolder"] as? String { lastProjectFolder = v }
        if let v = json["lastOpenFile"] as? String { lastOpenFile = v }
        if let f = json["windowFrame"] as? [String: Double] {
            windowFrame = SessionData.WindowFrame(
                x: f["x"] ?? 100, y: f["y"] ?? 100,
                width: f["width"] ?? 1400, height: f["height"] ?? 900)
        }
        if let v = json["sidebarWidth"] as? Double { sidebarWidth = v }
        if let v = json["pythiaWidth"] as? Double { pythiaWidth = v }
        if let v = json["fileBrowserOverlay"] as? Bool { fileBrowserOverlay = v }
        if let v = json["selectedSidebarTab"] as? String { selectedSidebarTab = v }
        if let v = json["activeThemeName"] as? String { activeThemeName = v }

        // Remove old file — the name now belongs to scope settings
        try? FileManager.default.removeItem(at: legacyURL)
    }
}