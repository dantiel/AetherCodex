import Foundation
import Combine

// MARK: - Environment Settings
//
// AetherCodex-affecting environment variables, editable in Settings → Environment.
// Two layers live here:
//
//   1. AetherCodex-specific overrides — `AETHERORACLE_PATH` (which Ruby checkout
//      the daemon boots from) and `AETHER_PROJECT_ROOT` (which project root the
//      bridge resolves). These mirror the keys `RubyBridge` already honours.
//   2. Arbitrary custom variables — free key/value pairs breathed into *both* the
//      editor context (the native SwiftUI process) and the Pythia context (the
//      Ruby daemon subprocess). Whatever a script, a grammar, or the Oracle
//      needs to see.
//
// `mergedEnvironment` is the single source of truth for "the environment the app
// and its children see": the inherited process environment, overlaid with the
// configured overrides (later wins).

/// One user-configured environment variable.
struct EnvironmentVariable: Identifiable, Codable, Equatable {
    var id = UUID()
    var key: String
    var value: String

    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
}

final class EnvironmentSettings: ObservableObject {
    static let shared = EnvironmentSettings()

    private enum Keys {
        static let custom = "AetherCodex.customEnvironment"
        static let aetherOraclePath = "AETHERORACLE_PATH"
        static let aetherProjectRoot = "AETHER_PROJECT_ROOT"
    }

    @Published var aetherOraclePath: String {
        didSet { defaults.set(aetherOraclePath, forKey: Keys.aetherOraclePath) }
    }
    @Published var aetherProjectRoot: String {
        didSet { defaults.set(aetherProjectRoot, forKey: Keys.aetherProjectRoot) }
    }
    @Published var customVariables: [EnvironmentVariable] {
        didSet { persistCustom() }
    }

    private let defaults = UserDefaults.standard

    private init() {
        aetherOraclePath = defaults.string(forKey: Keys.aetherOraclePath) ?? ""
        aetherProjectRoot = defaults.string(forKey: Keys.aetherProjectRoot) ?? ""
        if let data = defaults.data(forKey: Keys.custom),
           let decoded = try? JSONDecoder().decode([EnvironmentVariable].self, from: data) {
            customVariables = decoded
        } else {
            customVariables = []
        }
    }

    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customVariables) {
            defaults.set(data, forKey: Keys.custom)
        }
    }

    // MARK: - Resolution

    /// Configured overrides only — the layer that sits atop the inherited env.
    var overrides: [String: String] {
        var map: [String: String] = [:]
        let oracle = aetherOraclePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !oracle.isEmpty { map[Keys.aetherOraclePath] = oracle }
        let root = aetherProjectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty { map[Keys.aetherProjectRoot] = root }
        for v in customVariables {
            let key = v.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { map[key] = v.value }
        }
        return map
    }

    /// The full environment the editor process and its children should see.
    var mergedEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
    }

    /// Look up a variable the editor cares about (GIT_EDITOR, PATH, …), honouring
    /// configured overrides ahead of the inherited environment.
    func value(forKey key: String) -> String? {
        if let override = overrides[key] { return override }
        return ProcessInfo.processInfo.environment[key]
    }

    // MARK: - Editing

    func addVariable(key: String = "", value: String = "") {
        customVariables.append(EnvironmentVariable(key: key, value: value))
    }

    func removeVariable(at offsets: IndexSet) {
        customVariables.remove(atOffsets: offsets)
    }
}
