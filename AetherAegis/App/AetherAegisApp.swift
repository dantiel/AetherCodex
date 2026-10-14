import SwiftUI
import AppKit

/// AetherAegis — the shield companion. SwiftUI owns the lifecycle and window;
/// the single AppKit seam is the XPC mach-service listener, which has no public
/// SwiftUI equivalent.
///
/// The shield holds every system privilege on behalf of the editor: Screen
/// Recording, Accessibility, Automation, Full Disk Access. AetherCodex can be
/// rebuilt endlessly and never re-prompts — it asks the shield, and the shield
/// reflects.
@main
struct AetherAegisApp: App {
    @StateObject private var model = AegisModel()
    private let service = PrivilegeService()

    init() {
        // Keep SIGPIPE from killing the shield if a client vanishes mid-write.
        signal(SIGPIPE, SIG_IGN)
        service.start()
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        Window("Ægis", id: "shield") {
            AegisShieldView(model: model)
        }
        .defaultSize(width: 560, height: 640)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
