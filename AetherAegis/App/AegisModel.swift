import SwiftUI
import AppKit
import AegisProtocol

/// The live state of the shield: which facets reflect the light, plus the
/// request path for each. One observable object, one window.
@MainActor
final class AegisModel: ObservableObject {
    @Published private(set) var grants: [AegisFacet: Bool] = [:]

    init() {
        refresh()
    }

    func granted(_ facet: AegisFacet) -> Bool {
        grants[facet] ?? false
    }

    var grantedCount: Int {
        grants.values.filter { $0 }.count
    }

    /// Re-read every live facet (screen + hand) and restore the persisted ones.
    func refresh() {
        var next: [AegisFacet: Bool] = [:]
        next[.screenRecording] = Privileges.screenRecordingGranted()
        next[.accessibility] = Privileges.accessibilityGranted()
        next[.appleEvents] = Persisted.granted(.appleEvents)
        next[.fullDiskAccess] = Persisted.granted(.fullDiskAccess)
        grants = next
    }

    /// Request a facet. The screen and hand prompt live; the voice probes via
    /// AppleScript; the archive has no programmatic prompt, so we hand the
    /// pilgrim to System Settings and remember the journey when they return.
    func request(_ facet: AegisFacet) {
        switch facet {
        case .screenRecording:
            _ = Privileges.requestScreenRecording()
        case .accessibility:
            _ = Privileges.requestAccessibility()
        case .appleEvents:
            let ok = Privileges.requestAppleEvents()
            Persisted.set(.appleEvents, granted: ok)
        case .fullDiskAccess:
            openFullDiskAccessSettings()
        }
        refresh()
    }

    /// Reveal the Full Disk Access pane — the only facet with no in-app prompt.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Persistence for the facets without a live query (voice, archive). The
/// "current course" is written here — durable across launches, keyed by the
/// stable shield identity.
enum Persisted {
    private static let key = "aetherAegis.grants."

    static func granted(_ facet: AegisFacet) -> Bool {
        UserDefaults.standard.bool(forKey: key + facet.rawValue)
    }

    static func set(_ facet: AegisFacet, granted: Bool) {
        UserDefaults.standard.set(granted, forKey: key + facet.rawValue)
    }
}