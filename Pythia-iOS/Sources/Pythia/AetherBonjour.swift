import Foundation

/// Bonjour auto-discovery — finds the Mac's `_aethercodex._tcp` service without
/// ever knowing its IP. The Mac's daemon advertises via `dns-sd`; here we browse
/// `local.` and resolve each service to a `PeerContext` (host + port) that the
/// `OracleClient` can reach directly.
///
/// Delegate callbacks arrive on the main run loop (the browser is created on the
/// main thread), so `peers` is only ever touched from the main thread — the same
/// thread `PythiaCompanionModel` polls from under `@MainActor`.
public final class AetherBonjour: NSObject {
    public static let serviceType = "_aethercodex._tcp."

    public private(set) var peers: [PeerContext] = []
    public private(set) var isSearching = false

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []

    public func search() {
        peers.removeAll()
        services.removeAll()
        isSearching = true
        browser?.stop()
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        browser = b
    }

    public func stop() {
        browser?.stop()
        browser = nil
        isSearching = false
    }
}

extension AetherBonjour: NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser,
                                  didFind service: NetService,
                                  moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 3)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser,
                                  didRemove service: NetService,
                                  moreComing: Bool) {
        peers.removeAll { $0.host == service.hostName || $0.name == service.name }
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isSearching = false
    }
}

extension AetherBonjour: NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard var host = sender.hostName, sender.port > 0 else { return }
        // `hostName` may carry a trailing dot (fully-qualified `.local.`).
        while host.hasSuffix(".") { host.removeLast() }
        let peer = PeerContext(
            name: sender.name,
            host: host,
            port: sender.port,
            path: nil,
            version: nil,
            capabilities: [],
            busy: false,
            activeTaskCount: 0
        )
        if !peers.contains(where: { $0.id == peer.id }) {
            peers.append(peer)
        }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // A transient mDNS miss or a stale service — skip it; the browser keeps
        // watching and a later resolve will surface the peer.
    }
}
