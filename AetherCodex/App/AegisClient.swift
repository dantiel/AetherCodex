import Foundation
import AppKit
import AegisProtocol

/// AetherCodex → AetherAegis. The editor asks the shield to reflect light on its
/// behalf (capture the screen, move the hand, speak to other apps) without ever
/// holding the TCC grants itself. If the shield is not running, it is summoned
/// first; the connection then rides the mach service.
final class AegisClient {
    static let shared = AegisClient()

    private var connection: NSXPCConnection?

    /// Locate the shield app and, if absent, summon it. `activate` false brings
    /// it up headless — the shield raises its light without stealing the stage.
    private func summonShieldIfNeeded(activate: Bool = true) {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == AegisMach.bundleID }) {
            return
        }
        launchShield(activate: activate)
    }

    /// Open (or activate) the Ægis shield window.
    func openShield() {
        launchShield(activate: true)
    }

    private func launchShield(activate: Bool) {
        guard let url = Self.findShield() else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private static func findShield() -> URL? {
        let candidates: [URL] = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("AetherAegis.app"),
            URL(fileURLWithPath: "/Applications/AetherAegis.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/AetherAegis.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func makeConnection() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(machServiceName: AegisMach.serviceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: AegisPrivilegeProtocol.self)
        conn.resume()
        connection = conn
        return conn
    }

    /// Asynchronously capture the primary screen as PNG. Returns nil (with a
    /// message) when the shield is absent or the light is not yet reflected.
    func captureScreen() async -> (Data?, String?) {
        summonShieldIfNeeded()
        let remote = makeConnection().remoteObjectProxyWithErrorHandler { _ in
            // The shield may still be waking; the caller can retry.
        } as? AegisPrivilegeProtocol
        guard let remote else { return (nil, "The Ægis could not be reached.") }

        return await withCheckedContinuation { cont in
            remote.captureScreen { data, error in
                cont.resume(returning: (data, error))
            }
        }
    }

    /// The currently granted facets, keyed by raw `AegisFacet` value.
    func currentGrants() async -> [String: Bool] {
        summonShieldIfNeeded()
        let remote = makeConnection().remoteObjectProxyWithErrorHandler { _ in } as? AegisPrivilegeProtocol
        guard let remote else { return [:] }

        return await withCheckedContinuation { cont in
            remote.currentGrants { map in cont.resume(returning: map) }
        }
    }

    /// Raise a system notification via the shield — the only process that holds
    /// the notification grant. Returns true once the announcement is handed off.
    func announce(title: String, body: String) async -> Bool {
        summonShieldIfNeeded(activate: false)
        let remote = makeConnection().remoteObjectProxyWithErrorHandler { _ in } as? AegisPrivilegeProtocol
        guard let remote else { return false }

        return await withCheckedContinuation { cont in
            remote.announce(title: title, body: body) { sent in
                cont.resume(returning: sent)
            }
        }
    }
}