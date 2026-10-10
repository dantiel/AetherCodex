import Foundation

/// Swift-side ÆtherLink discovery — the same loop the Mac's `AetherLink.discover!`
/// and `FavouritesStore.AetherLinkClient` perform, but host-parameterised so the
/// iOS companion can scan a Mac's LAN address instead of `127.0.0.1`.
public struct AetherLinkClient {
    public static let scanRange = 4550...4610
    public static let heartbeatPath = "/aether/heartbeat"

    public init() {}

    /// Scan one host across the daemon port range, returning every live context.
    public static func discover(host: String) async -> [PeerContext] {
        await withTaskGroup(of: PeerContext?.self, returning: [PeerContext].self) { group in
            for port in scanRange {
                group.addTask { await heartbeat(host: host, port: port) }
            }
            var found: [PeerContext] = []
            for await context in group {
                if let context { found.append(context) }
            }
            return found.sorted { $0.port < $1.port }
        }
    }

    public static func heartbeat(host: String, port: Int) async -> PeerContext? {
        guard let url = URL(string: "http://\(host):\(port)\(heartbeatPath)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String, !name.isEmpty else { return nil }
            let tasks = json["active_tasks"] as? [Any] ?? []
            return PeerContext(
                name: name,
                host: host,
                port: json["port"] as? Int ?? port,
                path: json["path"] as? String,
                version: json["version"] as? String,
                capabilities: json["capabilities"] as? [String] ?? [],
                busy: json["busy"] as? Bool ?? false,
                activeTaskCount: tasks.count
            )
        } catch {
            return nil
        }
    }
}
