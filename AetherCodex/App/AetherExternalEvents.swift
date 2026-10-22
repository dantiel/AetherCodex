import Cocoa

/// AppKit seam for the Finder / `open -a` document event (`odoc`).
///
/// SwiftUI's `.onOpenURL` covers the `aethercodex://` scheme, but `open -a
/// AetherCodex file.txt` delivers a `kAEOpenDocuments` Apple Event instead —
/// SwiftUI exposes no public hook for it. Captured here and re-posted as
/// `.openFileInEditor`, the same channel the menu, Ruby and FileLinkResolver
/// already drive.
@MainActor
final class AetherExternalEvents: NSObject {

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor,
                                           withReply reply: NSAppleEventDescriptor) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else { return }

        // `odoc` normally arrives as a list of file URLs, even for one file;
        // accept a lone descriptor too.
        let items: [NSAppleEventDescriptor]
        if directObject.numberOfItems > 0 {
            items = (1...directObject.numberOfItems).compactMap { directObject.atIndex($0) }
        } else {
            items = [directObject]
        }

        for item in items {
            guard let url = Self.fileURL(from: item) else { continue }
            NotificationCenter.default.post(name: .openFileInEditor, object: url)
        }
    }

    /// `odoc` payloads are `typeFileURL` ("file:///…") on the Finder path; the
    /// coercion covers the rare `typeAlias` form.
    private static func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        let asFileURL = descriptor.coerce(toDescriptorType: typeFileURL)
        guard let string = asFileURL?.stringValue ?? descriptor.stringValue,
              let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }
}
