import SwiftUI
import AppKit

/// The SwiftUI application lifecycle.
///
/// SwiftUI owns the process, every window, and the menu. The secondary surfaces
/// — Settings, Project Settings, Find & Replace, Go to File, Æther Debug, Aegis
/// — are *scenes*, not `NSWindowController`s: placement, level, chrome and
/// single-instance behaviour are declared below rather than assembled in code
/// (`defaultWindowPlacement`, `windowLevel`, `windowStyle`, `Window` vs
/// `WindowGroup`). `AppScene` carries the payloads and the open/dismiss actions
/// to callers that live outside a view — the menu, the responder chain, Ruby.
///
/// The single AppKit seam left at the root is *window chrome*: macOS exposes no
/// public SwiftUI API for nesting the standard window buttons inside a rounded,
/// full-size content canvas, so `MainWindowController` adopts the hosting
/// `NSWindow` for exactly that (plus parenting the file-browser overlay panel).
@main
struct AetherCodexApp: App {
    @StateObject private var shell = MainWindowController()
    private let actions = AppActions()
    private let externalEvents = AetherExternalEvents()

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
        Window("ÆtherCodex", id: AppWindowID.main) {
            shell.rootView
                .frame(minWidth: 800, minHeight: 600)
                .appScene(AppWindowID.main)
                .onAppear { shell.adoptHostWindow() }
                .onOpenURL { url in _ = FileLinkResolver.open(url) }
        }
        .defaultSize(width: 1400, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { AetherCommands(shell: shell, actions: actions) }

        // ── Secondary surfaces ──
        //
        // Each entry below replaces a hand-built window. Read the modifiers as
        // the answer to "what did the controller do by hand?":
        //
        //   defaultWindowPlacement  ← NSScreen.main spotlight arithmetic
        //   windowLevel             ← panel.level = .floating
        //   windowStyle             ← styleMask / titleVisibility / contentView
        //   windowBackground…       ← isMovableByWindowBackground
        //   restorationBehavior     ← isReleasedWhenClosed (kept warm, not stored)
        //   Window (not Group)      ← NSApp.windows.first(where:) single-instance
        //
        // `defaultLaunchBehavior(.suppressed)` states the invariant outright: no
        // secondary surface ever appears at launch — only when asked for.

        Settings {
            SettingsView().appScene(AppWindowID.settings)
        }

        Window("Project Settings", id: AppWindowID.projectSettings) {
            ProjectSettingsView(initialTab: AppScene.shared.projectSettingsTab)
                .appScene(AppWindowID.projectSettings)
        }
        .defaultSize(width: 640, height: 600)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        UtilityWindow("Find & Replace", id: AppWindowID.findReplace) {
            FindReplaceScene().appScene(AppWindowID.findReplace)
        }
        .defaultSize(width: 620, height: 420)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        UtilityWindow("Æther Debug", id: AppWindowID.debugLog) {
            AetherDebugScene().appScene(AppWindowID.debugLog)
        }
        .defaultSize(width: 440, height: 480)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Aegis", id: AppWindowID.aegis) {
            AegisWidgetScene().appScene(AppWindowID.aegis)
        }
        .defaultSize(width: 400, height: 460)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The palette is `.plain` — no titlebar at all, which is also why the
        // old `KeyablePanel` subclass (AppKit refuses key status to a window
        // without a title or resize bar) has no counterpart: a scene window can
        // always become key, so a search field in it is typeable immediately.
        UtilityWindow("Go to File", id: AppWindowID.goToFile) {
            GoToFileScene().appScene(AppWindowID.goToFile)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .defaultWindowPlacement { _, _ in
            // Spotlight geometry: horizontally centred, upper third.
            WindowPlacement(UnitPoint(x: 0.5, y: 0.28), width: 560, height: 360)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}