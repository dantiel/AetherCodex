import Foundation

/// The shared contract between AetherCodex (the editor shell) and AetherAegis
/// (the privilege-holding shield). Both processes link this module so the
/// @objc protocol resolves to identical selectors on each side of the XPC
/// mach-service boundary.
///
/// AetherAegis is the *only* process that ever touches the screen, the cursor,
/// or another application. Because its code signature stays stable across
/// AetherCodex rebuilds, the TCC grants it holds survive the editor's constant
/// development — the shield keeps reflecting the divine light while the athanor
/// is endlessly remelted.
@objc public protocol AegisPrivilegeProtocol {
    /// The facets currently granted, keyed by raw `AegisFacet` value.
    func currentGrants(reply: @escaping ([String: Bool]) -> Void)

    /// Request a facet (screen-recording, accessibility, …). Returns the state
    /// after the request — true once the light reflects.
    func requestAccess(_ facet: String, reply: @escaping (Bool) -> Void)

    /// Capture the primary screen as PNG data. `error` is nil on success.
    func captureScreen(reply: @escaping (Data?, String?) -> Void)

    /// Ring the bell and raise a system notification — the light of the
    /// announcement. Used when the oracle pauses to consult the user, so the
    /// question is felt even when the editor window is not frontmost.
    func announce(title: String, body: String, reply: @escaping (Bool) -> Void)
}

/// The mach service both sides rendezvous on. The name is the shared star the
/// two processes navigate by.
public enum AegisMach {
    public static let serviceName = "com.aethercodex.aegis"
    public static let bundleID   = "com.aethercodex.aegis"
}

/// The facets of the shield — each a kind of light the Ægis can reflect.
/// Screen, hand, voice, archive: four lights, one mirror.
public enum AegisFacet: String, CaseIterable, Sendable {
    case screenRecording
    case accessibility
    case appleEvents
    case fullDiskAccess
    case notifications
}