import Foundation
import AppKit
import AegisProtocol

/// The XPC side of the shield. AetherCodex connects to the mach service named
/// `AegisMach.serviceName` and asks the shield to reflect light on its behalf.
/// The shield is the sole process that performs privileged operations; the
/// editor stays TCC-innocent no matter how often it is rebuilt.
final class PrivilegeService: NSObject, NSXPCListenerDelegate, AegisPrivilegeProtocol {
    private var listener: NSXPCListener?

    func start() {
        listener = NSXPCListener(machServiceName: AegisMach.serviceName)
        listener?.delegate = self
        listener?.resume()
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AegisPrivilegeProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: AegisPrivilegeProtocol

    func currentGrants(reply: @escaping ([String: Bool]) -> Void) {
        var map: [String: Bool] = [:]
        for facet in AegisFacet.allCases {
            switch facet {
            case .screenRecording: map[facet.rawValue] = Privileges.screenRecordingGranted()
            case .accessibility:   map[facet.rawValue] = Privileges.accessibilityGranted()
            case .appleEvents:     map[facet.rawValue] = Persisted.granted(facet)
            case .fullDiskAccess:  map[facet.rawValue] = Persisted.granted(facet)
            }
        }
        reply(map)
    }

    func requestAccess(_ facet: String, reply: @escaping (Bool) -> Void) {
        guard let f = AegisFacet(rawValue: facet) else { reply(false); return }
        switch f {
        case .screenRecording:
            reply(Privileges.requestScreenRecording())
        case .accessibility:
            reply(Privileges.requestAccessibility())
        case .appleEvents:
            let ok = Privileges.requestAppleEvents()
            Persisted.set(.appleEvents, granted: ok)
            reply(ok)
        case .fullDiskAccess:
            // No programmatic prompt exists; report the persisted memory.
            reply(Persisted.granted(.fullDiskAccess))
        }
    }

    func captureScreen(reply: @escaping (Data?, String?) -> Void) {
        Task {
            if let data = await Privileges.capturePrimaryScreen() {
                reply(data, nil)
            } else if !Privileges.screenRecordingGranted() {
                reply(nil, "Screen Recording is not granted. Open the Ægis and reflect the screen light first.")
            } else {
                reply(nil, "The screen could not be captured.")
            }
        }
    }
}