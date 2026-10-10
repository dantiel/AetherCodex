import Foundation

/// Persists the last-reached oracle peer so App Intents can route a turn without
/// the live UI — Siri/Spotlight/Shortcuts run outside the app process and need a
/// durable `host:port` to reach the Mac's `limen.rb` daemon.
///
/// Uses `UserDefaults.standard` for the package. A production app target should
/// move these keys into an App Group (and an intent extension) so the intent and
/// the app share one container; the store is the single persistence point either way.
public struct OracleConnectionStore {
    public static let shared = OracleConnectionStore()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let host = "aether.oracle.host"
        static let port = "aether.oracle.port"
    }

    /// The last peer the companion connected to, if any.
    public var lastPeer: PeerContext? {
        let port = defaults.integer(forKey: Key.port)
        guard port > 0 else { return nil }
        let host = defaults.string(forKey: Key.host) ?? "127.0.0.1"
        return PeerContext(
            name: "AetherCodex",
            host: host,
            port: port,
            path: nil,
            version: nil,
            capabilities: [],
            busy: false,
            activeTaskCount: 0
        )
    }

    public func save(host: String, port: Int) {
        defaults.set(host, forKey: Key.host)
        defaults.set(port, forKey: Key.port)
    }

    public func clear() {
        defaults.removeObject(forKey: Key.host)
        defaults.removeObject(forKey: Key.port)
    }

    /// An `OracleClient` bound to the last-reached peer, or `nil` if never connected.
    public func makeClient() -> OracleClient? {
        guard let peer = lastPeer else { return nil }
        return OracleClient(host: peer.host, port: peer.port)
    }
}
