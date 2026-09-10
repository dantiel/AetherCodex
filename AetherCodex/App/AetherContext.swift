import Foundation
import SwiftUI

// MARK: - Aether Context

/// Polymorphic project-context coordinator — **"ICH bin der ÆTHER"**.
///
/// Resolves the `.aethercodex` root for any opened file or folder and pushes it
/// across the bridge to the daemon, so the whole window (editor, file browser,
/// Pythia, AI) inherits *one* project identity — regardless of which subdirectory
/// was opened. There is no per-window context state: the context *is* the window.
@MainActor
final class AetherContext: ObservableObject {
    static let shared = AetherContext()

    /// Resolved project root (the directory carrying `.aethercodex`, or the
    /// nearest opened directory when no config exists yet).
    @Published var root: String?

    /// Advertised context name — `name:` from `.aethercodex`, else folder basename.
    @Published var name: String?

    /// Path to the governing `.aethercodex`, when one exists.
    @Published var configPath: String?

    /// Memory db the daemon is currently attached to (informational).
    @Published var memoryDB: String?

    private var lastActivated: String?

    /// Walk up from `path` (file or directory) to the nearest `.aethercodex`.
    /// Returns the directory that carries the config; if none carries one, the
    /// originally-opened directory becomes the root. Mirrors `resolve_project_root`
    /// in the daemon so both sides agree on identity.
    static func resolveRoot(for path: String) -> (root: String, configPath: String?)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        let openedDir = isDir.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent

        var current = openedDir
        while true {
            let candidate = (current as NSString).appendingPathComponent(".aethercodex")
            if fm.fileExists(atPath: candidate) {
                return (current, candidate)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty {
                return (openedDir, nil)
            }
            current = parent
        }
    }

    /// Resolve and activate the project context for the given file/folder URL.
    func activate(for url: URL) {
        guard let resolved = Self.resolveRoot(for: url.path) else { return }
        activate(root: resolved.root, configPath: resolved.configPath)
    }

    /// Activate a resolved root. No-ops when the root is unchanged, so repeated
    /// opens within the same project never thrash the daemon.
    func activate(root: String, configPath: String?) {
        guard lastActivated != root else { return }
        lastActivated = root

        self.root = root
        self.configPath = configPath
        self.name = (root as NSString).lastPathComponent

        Task {
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                if let info = try await RubyBridge.shared.activateContext(path: root) {
                    await MainActor.run {
                        if let n = info["name"] as? String, !n.isEmpty { self.name = n }
                        if let cp = info["config_path"] as? String, !cp.isEmpty { self.configPath = cp }
                        if let db = info["memory_db"] as? String { self.memoryDB = db }
                    }
                }
            } catch {
                // Context activation is best-effort — never block the editor.
            }
        }
    }
}
