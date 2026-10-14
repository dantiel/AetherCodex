import SwiftUI
import AppKit

/// The SwiftUI application lifecycle.
///
/// SwiftUI owns the process, the window, and the menu. The single AppKit seam
/// left at the root is *window chrome*: macOS exposes no public SwiftUI API for
/// nesting the standard window buttons inside a rounded, full-size content
/// canvas, so `MainWindowController` adopts the hosting `NSWindow` for exactly
/// that (plus parenting the file-browser overlay panel).
@main
struct AetherCodexApp: App {
    @StateObject private var shell = MainWindowController()
    private let actions = AppActions()

    init() {
        // Never let a broken daemon pipe (SIGPIPE) kill the whole app: the raw
        // write(2) in RubyBridge should return EPIPE so the revive path can run.
        signal(SIGPIPE, SIG_IGN)
        FontBundler.registerAll()
        RubyBridge.shared.initialize()

        // No public SwiftUI hook for "the app is terminating" — clean the daemon up.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            RubyBridge.shared.cleanup()
        }

        // SwiftUI's `Window` scene only surfaces once the app is activated, and a
        // process started straight from a shell — the launch path `bundle_app.sh`
        // advertises — never is. The old AppKit root activated explicitly for the
        // same reason. Deferred to the main queue so it lands after
        // `applicationDidFinishLaunching`.
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        Window("ÆtherCodex", id: "main") {
            shell.rootView
                .frame(minWidth: 800, minHeight: 600)
                .onAppear { shell.adoptHostWindow() }
        }
        .defaultSize(width: 1400, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { AetherCommands(shell: shell, actions: actions) }
    }
}