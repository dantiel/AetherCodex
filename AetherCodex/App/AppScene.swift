import AppKit
import Combine
import SwiftUI

// MARK: - Window identity

/// Ids of the app's secondary SwiftUI scenes.
///
/// A scene is addressed by string, so every auxiliary surface names itself here.
/// `AetherCodexApp.body` declares the matching `Window`/`UtilityWindow` scenes.
enum AppWindowID {
    static let main = "main"
    static let settings = "settings"
    static let projectSettings = "projectSettings"
    static let findReplace = "findReplace"
    static let goToFile = "goToFile"
    static let debugLog = "debugLog"
    static let aegis = "aegis"
}

// MARK: - Payloads

/// One invocation of the Go to File palette: where it searches, what is already
/// open, and what to do with the chosen URL.
///
/// The result callback used to be private state of an `NSWindowController` that
/// kept itself alive with `objc_setAssociatedObject`; it now travels with the
/// request.
struct GoToFileRequest: Identifiable {
    let id = UUID()
    let projectRoot: URL
    let currentURL: URL?
    let openPaths: Set<String>
    let onSelect: (URL) -> Void
}

// MARK: - Router

/// The bridge from *action* to *scene*.
///
/// `openWindow`, `dismissWindow` and `openSettings` are environment actions:
/// they exist only inside a `View`. The menu, the responder chain and the Ruby
/// daemon all call from outside one, so a root view installs them once
/// (`View.appScene(_:)`) and the rest of the app calls through here.
///
/// Liveness is mirrored back from each scene's own `onAppear`/`onDisappear`.
/// That is what lets `toggle(_:)` choose between opening and dismissing without
/// interrogating AppKit — the `NSApp.windows.first(where:)` probe the old
/// controllers used, which silently missed a window it did not recognise.
@MainActor
final class AppScene: ObservableObject {

    static let shared = AppScene()

    private init() {}

    private var openAction: ((String) -> Void)?
    private var dismissAction: ((String) -> Void)?
    private var settingsAction: (() -> Void)?
    private var findHideSink: AnyCancellable?

    /// Ids whose scene is currently mounted.
    @Published private(set) var live: Set<String> = []

    // MARK: Payloads

    /// Section the Settings surface should show.
    @Published var settingsSection: SettingsSection = .newFile

    /// Tab the Project Settings window should show when it mounts.
    @Published var projectSettingsTab: ProjectSettingsView.Tab = .general

    /// The model Find & Replace is bound to; nil while the panel is folded away.
    @Published private(set) var findModel: FindReplaceModel?

    /// The pending Go to File invocation.
    @Published private(set) var goToFile: GoToFileRequest?

    // MARK: Installation

    func install(open: @escaping (String) -> Void,
                 dismiss: @escaping (String) -> Void,
                 settings: @escaping () -> Void) {
        openAction = open
        dismissAction = dismiss
        settingsAction = settings
    }

    func markLive(_ id: String) { live.insert(id) }
    func markGone(_ id: String) { live.remove(id) }

    // MARK: Primitives

    func open(_ id: String) { openAction?(id) }
    func dismiss(_ id: String) { dismissAction?(id) }

    /// Open when closed, dismiss when open — the panel semantics the AppKit
    /// controllers hand-rolled with `orderFrontRegardless`/`orderOut`.
    func toggle(_ id: String) {
        if live.contains(id) { dismiss(id) } else { open(id) }
    }

    // MARK: Surfaces

    /// ⌘, and the Appearance item steer one already-existing surface.
    func openSettings(section: SettingsSection = .newFile) {
        settingsSection = section
        settingsAction?()
    }

    func openProjectSettings(contextTab: Bool = false) {
        projectSettingsTab = contextTab ? .context : .general
        open(AppWindowID.projectSettings)
        // A window that is already up keeps its own tab state; the notification
        // is what steers that one.
        if contextTab {
            NotificationCenter.default.post(name: .projectSettingsOpenContextTab, object: nil)
        }
    }

    func toggleDebugLog() { toggle(AppWindowID.debugLog) }

    func toggleAegisWidget() { toggle(AppWindowID.aegis) }

    /// Bind the find window to `model` and raise it.
    ///
    /// The window folds away whenever the model reports itself invisible — Esc,
    /// the close button, or a `cancel()` from the responder chain — which is the
    /// sink the window controller used to own.
    func presentFind(_ model: FindReplaceModel) {
        findModel = model
        findHideSink = model.$isVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard !visible else { return }
                self?.findModel = nil
                self?.findHideSink = nil
                self?.dismiss(AppWindowID.findReplace)
            }
        open(AppWindowID.findReplace)
    }

    func showGoToFile(projectRoot: URL, currentURL: URL? = nil,
                      openPaths: Set<String> = [], onSelect: @escaping (URL) -> Void) {
        goToFile = GoToFileRequest(projectRoot: projectRoot, currentURL: currentURL,
                                   openPaths: openPaths, onSelect: onSelect)
        open(AppWindowID.goToFile)
    }
}

// MARK: - Scene attachment

extension View {
    /// Installs the scene-router actions and mirrors this scene's liveness back
    /// into `AppScene`.
    ///
    /// The liveness write is deferred one main-queue turn: publishing from
    /// `onAppear` while SwiftUI is still updating the view is a state-during-
    /// update write.
    func appScene(_ id: String) -> some View {
        modifier(AppSceneAttachment(id: id))
    }
}

@MainActor
private struct AppSceneAttachment: ViewModifier {
    let id: String

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppScene.shared.install(
                    open: { openWindow(id: $0) },
                    dismiss: { dismissWindow(id: $0) },
                    settings: { openSettings() }
                )
                DispatchQueue.main.async { AppScene.shared.markLive(id) }
            }
            .onDisappear {
                DispatchQueue.main.async { AppScene.shared.markGone(id) }
            }
    }
}
